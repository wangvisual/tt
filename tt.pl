#! /depot/perl-5.22.0/bin/perl

use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';
use feature qw(state signatures postderef switch);
no warnings qw(experimental::signatures experimental::postderef experimental::smartmatch);
use FindBin qw($RealBin);
use lib "$RealBin";
use lib "$RealBin/lib/perl5";
use Encode;
#use CGI qw/:all -utf8/; # -utf8 requires STDIN not UTF8, so can't use it, we will use Encode module to decode ourself
use CGI qw/:all/;
use Data::Dumper;
use Mail::Sendmail;
use JSON::XS;
use Net::LDAP;

use constant {
    DEFAULT_POINT => 1600,
    STAGE_END => 100,
};
my $stage_name = { 0 => '报名', 1 => '循环赛', 2 => '淘汰赛', &STAGE_END() => '结束' };

use settings;
use db;

my $imgd = 'etc';
my $extjs = 'https://cdnjs.cloudflare.com/ajax/libs/extjs/3.4.1-1';

my $userid = '';
my ($q,$db);
my $perPage = 40;

# https://perldoc.perl.org/Encode/MIME/Header.html
# http://hansekbrand.se/code/UTF8-emails.html
sub send_html_email($to, $cc, $subject, $msg) {
    my %mail = (
        From             => encode("MIME-Header", $settings::title) . ' <' . ($ENV{SERVER_ADMIN} // 'unknown') . '>',
        To               => $to,
        Cc               => $cc,
        Subject          => encode("MIME-Header", $subject),
        Message          => encode('utf8', $msg),
        'content-type'   => 'text/html; charset="utf-8"',
        'Auto-Submitted' => 'auto-generated', # https://tools.ietf.org/html/rfc3834
    );
    sendmail(%mail) or print STDERR "Sendmail: $Mail::Sendmail::error\n";
}
sub getUserInfo($uid = undef) {
    $uid //= $q->param('userid');
    my $fail = {success=>0, user=>[{}]};

    # In DB?
    my @res = $db->exec( "SELECT userid, name, cn_name, nick_name, email, logintype, gender, point FROM USERS WHERE USERID=?", [$uid], 1 );
    return $fail if scalar @res > 1;
    return {success=>1, user=>[$res[0]]} if scalar @res == 1;

    # Try LDAP if not found in db
    my ($ldap, $mesg, $email, $name, $employeeNumber);
    $ldap = Net::LDAP->new( $settings::ldapserver ) or do { print "$@"; return $fail; };
    $mesg = $ldap->bind; # an anonymous bind
    $mesg = $ldap->search(
                           base   => $settings::baseDN,
                           filter => "(uid=" . $uid .")",
                           attrs  => [$settings::name, $settings::email, $settings::employeeNumber, 'cn']
                         );
    $mesg->code && do { print $mesg->error; return $fail };
    return $fail if $mesg->count != 1;

    foreach my $entry ($mesg->entries) {
        $name = ($entry->get_value($settings::name))[0] || ($entry->get_value('cn'))[0] || $uid;
        $email = ($entry->get_value($settings::email))[0] || '';
        $employeeNumber = ($entry->get_value($settings::employeeNumber))[0] || '';
    }
    $mesg = $ldap->unbind;

    # Save to DB if not in.
    $db->exec( "INSERT INTO USERS(userid,name,email,employeeNumber,logintype,gender,point) VALUES(?,?,?,?,?,?,?);", [$uid, $name, $email, $employeeNumber, 1, '未知', '0'], 0 );

    { success=>1, user=>[{userid=>$uid, name => $name, email => $email, employeeNumber => $employeeNumber, logintype => 1, gender=> '未知', point => 0}] };
}

sub getGeneralInfo() {
    getUserInfo($userid);
}

sub get_param($name, $default = undef) {
    decode('UTF-8', $q->param($name)) // $default;
}

sub get_multi_param($name, $default = undef) {
    my @values = map {; decode('UTF-8', $_); } $q->multi_param($name);
    return $default if defined $default && !scalar @values;
    \@values;
}

sub isAdmin($id=$userid) {
    my @val = $db->exec('SELECT logintype FROM USERS WHERE userid=?;', [$id], 1);
    return 0 if $db->{err} || scalar @val == 0;
    return 1 if $val[0]->{logintype} == 0;
    # or there's no admin yet
    my @anyone = $db->exec('SELECT count(logintype) AS c FROM USERS WHERE logintype=?;', [0], 1);
    return 0 if $db->{err} || scalar @anyone == 0;
    !$val[0]->{c};
}

sub editUser() {
    my $id = get_param('userid');
    return { success=>0, msg=>'Invalid input' } if !$id;
    getUserInfo($id);
    my $nick_name = get_param('nick_name', '');
    my $cn_name = get_param('cn_name', '');
    my $logintype = get_param('logintype', 1); # normal
    my $gender = get_param('gender', 'Male');
    my $point = get_param('point') || 0;

    my $admin;
    # check permissions, only admin can set another as admin/change point directly
    return { success=>0, msg=>"Permission denied, Can't change ${id}'s value" } if $id ne $userid && ! ($admin = isAdmin($userid));
    if ( $logintype == 0 ) {
        $admin //= isAdmin($userid);
        return { success=>0, msg=>"Permission denied, Can't set $id as admin" } if !$admin;
    }
    if ( $point > 0 ) {
        $admin //= isAdmin($userid);
        if ( !$admin ) {
            my @val = $db->exec('SELECT point FROM USERS WHERE userid=?;', [$id], 1);
            my $original_point_zero = ( $val[0]->{point} == 0 );
            $point = 0 if $val[0]->{point} == $point; # no need to update point
            return { success=>0, msg=>"Permission denied, Can't set ${id}'s point" } if $point > 0 && !$original_point_zero;
        }
    }
    my $success = 1;
    $db->exec('UPDATE USERS set nick_name=?,cn_name=?,logintype=?,gender=? where userid=?;', [$nick_name, $cn_name, $logintype, $gender, $id], 0);
    $success = 0 if $db->{err};

    if ( $success && $point > 0 ) {
        $db->exec('UPDATE USERS set point=? where userid=?;', [$point, $id], 0);
        $success = 0 if $db->{err};
    }

    { success=>$success, msg=>$db->{errstr} };
}

sub getPointList() {
    my $siries_id = get_param('siries_id') || 0;
    my $stage = get_param('stage') || 0;
    my $fail = { success=>0, users => [] };
    my @users = $db->exec('SELECT userid,name,nick_name,employeeNumber,cn_name,gender,point FROM USERS WHERE logintype<=? AND point>? ORDER BY userid ASC;', [1,0], 1);
    return $fail if $db->{err};
    my @win = $db->exec('SELECT sum(win) AS win, sum(lose) AS lose, userid FROM MATCH_DETAILS GROUP BY userid;', undef, 1);
    return $fail if $db->{err};
    my $user = {}; # { weiw => { win => 0, fail => 1 } }
    foreach (@win) {
        $user->{$_->{userid}}->{win} = $_->{win};
        $user->{$_->{userid}}->{lose} = $_->{lose};
    }
    if ( $siries_id && $stage >= 0 ) {
        my @siries = $db->exec('SELECT userid FROM SERIES_USERS WHERE siries_id=? AND stage=?;', [$siries_id, $stage], 1);
        return $fail if $db->{err};
        foreach (@siries) {
            $user->{$_->{userid}}->{siries} = 1;
        }
    }
    foreach my $p ( qw(win lose siries) ) {
        foreach (@users) {
            $_->{$p} = $user->{$_->{userid}}->{$p} // 0;
        }
    }
    { success=>1, users=>\@users };
}

# http://www.ctta.cn/xhgg/zcfg/2017/0621/149168.html
# 中国乒乓球协会竞赛积分管理办法(试行)
# http://cntt.sports.cn/sshg/2014hyls/tzgg/2014-08-03/2349855.html
# 中国乒乓球协会积分赛介绍
sub calcPoints($pure_win, $point1, $point2, $ref1, $ref2) {
    my @table = (
        [12, 8, 8],
        [37, 7, 10],
        [62, 6, 13],
        [87, 5, 16],
        [112, 4, 20],
        [137, 3, 25],
        [162, 2, 30],
        [187, 2, 35],
        [212, 1, 40],
        [237, 1, 45],
        [1000000, 0, 50],
    );
    my $higher_point_win = ($ref1 - $ref2) * $pure_win > 0 ? 1 : 0;
    my $diff = abs($ref1 - $ref2);
    my $point;
    foreach (@table) {
        if ( $diff <= $_->[0] ) {
            $point = $higher_point_win ? $_->[1] : $_->[2];
            last;
        }
    }
    $point *= -1 if $pure_win < 0;
    $point1 += $point;
    $point2 -= $point;
    ($point1, $point2);
}

sub editMatch() {
    my $match_id = get_param('match_id') || -1;
    return { success => 0, msg => '非管理员不能修改比赛结果'  } if $match_id > 0 && !isAdmin();
    return { success => 0, msg => '管理员也不能修改比赛结果'  } if $match_id > 0;
    my $siries_id = get_param('siries_id') || -1;
    my $date = get_param('date', ''); # 2019-08-17
    my $userid1 = get_param('userid1', '');
    my $userid2 = get_param('userid2', '');
    return { success => 0, msg => '输入信息不正确' } if $siries_id < 0 || !$date || !$userid1 || !$userid2 || $userid1 eq $userid2;
    my @series = $db->exec('SELECT siries_id, siries_name, stage FROM SERIES where siries_id=? and stage<?;', [$siries_id, STAGE_END], 1);
    return { success => 0, msg => '找不到合适的比赛项目' } if $db->{err} || scalar @series != 1;
    my @games; # ( [11, 7], [9, 11] )
    foreach my $i (1..7) {
        $games[$i][0] = get_param("game${i}_point1") || 0;
        $games[$i][1] = get_param("game${i}_point2") || 0;
    }
    @games = grep { defined $_ && $_->[0] != $_->[1] } @games;
    return { success => 0, msg => '没有每局比分' } if !scalar @games;
    my $win1 = scalar grep { $_->[0] > $_->[1] } @games;
    my $win2 = scalar @games - $win1;
    return { success => 0, msg => '分不出胜负' } if $win1 == $win2;

    my $comment = get_param('comment', '');

    # get the old point and calc the new point
    my @points = $db->exec('SELECT userid, point, email, name || ", " || cn_name || ", " || nick_name as full_name FROM USERS WHERE userid IN (?,?);', [$userid1, $userid2], 1);
    return { success => 0, msg => '找不到参赛人员' } if $db->{err} || scalar @points != 2;
    my %names;
    my @to;
    my ($point1, $point2, $ref1, $ref2);
    foreach (@points) {
        $point1 = $_->{point} || DEFAULT_POINT if $_->{userid} eq $userid1;
        $point2 = $_->{point} || DEFAULT_POINT if $_->{userid} eq $userid2;
        push @to, $_->{email} if $_->{email} =~ /\@/;
        $names{$_->{userid}} = $_->{full_name};
    }
    # 自由约战使用当前积分作为参考分，其它比赛使用快照积分
    my $basePoint = getBasePoint($siries_id, $siries_id == 1 ? 'users' : 'capture');
    $ref1 = $basePoint->{$userid1} || $point1;
    $ref2 = $basePoint->{$userid2} || $point2;
    my ($new_point1, $new_point2) = calcPoints($win1-$win2, $point1, $point2, $ref1, $ref2);
    my ($diff1, $diff2) = ($new_point1 - $point1, $new_point2 - $point2);
    my $win = $win1 - $win2 > 0 ? 1 : 0;
    my $lose = 1 - $win;

    # FIXME, use real stage and group
    my $stage = $siries_id == 1 ? 0 : 1; my $group_number = 1;
    # update DB using transcation
    eval {
        $db->{dbh}->begin_work;
        $db->exec("INSERT INTO MATCHES(siries_id, stage, group_number, date, comment) VALUES(?,?,?,?,?);", [$siries_id, $stage, $group_number, $date, $comment], 2, 0);
        $match_id = $db->{last_insert_id};
        die "Invalid siries_id\n" if $match_id <= 0;
        $db->exec("INSERT INTO MATCH_DETAILS(match_id, userid, point_ref, point_before, point_after, win, lose, game_win, game_lose, userid2) VALUES(?,?,?,?,?,?,?,?,?,?);",
                  [$match_id, $userid1, $ref1, $point1, $new_point1, $win, $lose, $win1, $win2, $userid2], 0, 0);
        $db->exec("INSERT INTO MATCH_DETAILS(match_id, userid, point_ref, point_before, point_after, win, lose, game_win, game_lose, userid2) VALUES(?,?,?,?,?,?,?,?,?,?);",
                  [$match_id, $userid2, $ref2, $point2, $new_point2, $lose, $win, $win2, $win1, $userid1], 0, 0);
        foreach (my $number = 0;  $number < scalar @games; $number++ ) {
            $db->exec("INSERT INTO GAMES(match_id, game_number, userid, win, lose) VALUES(?,?,?,?,?);",
                      [$match_id, $number, $userid1, $games[$number]->[0], $games[$number]->[1]], 0, 0);
            $db->exec("INSERT INTO GAMES(match_id, game_number, userid, win, lose) VALUES(?,?,?,?,?);",
                      [$match_id, $number, $userid2, $games[$number]->[1], $games[$number]->[0]], 0, 0);
        }
        $db->exec('UPDATE USERS set point=? where userid=?;', [$new_point1, $userid1], 0, 0);
        $db->exec('UPDATE USERS set point=? where userid=?;', [$new_point2, $userid2], 0, 0);
        # User may not enroll yet, add it now
        $db->exec('INSERT OR IGNORE INTO SERIES_USERS(siries_id, stage, userid, original_point, group_number) VALUES(?,?,?,?,?)',
                  [$siries_id, $stage, $userid1, $ref1, $group_number], 0, 0);
        $db->exec('INSERT OR IGNORE INTO SERIES_USERS(siries_id, stage, userid, original_point, group_number) VALUES(?,?,?,?,?)',
                  [$siries_id, $stage, $userid2, $ref2, $group_number], 0, 0);
        $db->{dbh}->commit();
    };
    if ( $@ ) {
        $db->{dbh}->rollback();
        return { success => 0, msg => "DB fail: $db->{errstr}" };
    }

    if ( $settings::mail ) {
        my $cc = '';
        if ( $settings::mail >= 2 ) { # CC admin
            my @admin = $db->exec('SELECT email FROM USERS WHERE logintype=?;', [0], 1);
            if ( !$db->{err} ) {
                $cc = join(', ', map {; $_->{email} } @admin);
            }
        }
        my $game_details = join("\n", map {; '<tr><td>' . $_->[0] . '</td><td>' . $_->[1] . '</td></tr>'; } @games);
        my $https = ($ENV{HTTPS} // '' ) eq 'ON' ? 'https' : 'http';
        my $content =<<EOT;
<html>
    <head>
      <style type='text/css'>
          table,tr,th,td {
            border: 1px solid black;
            border-collapse: collapse;
            padding-right: 32px;
          }
          th {
            background-color: darkorchid;
            color: white;
          }
          tr:hover {background-color: #f5f5f5;}
          tr:nth-child(even) {background-color: #f2f2f2;}
      </style>
    </head>
    <body>
    <h1>$series[0]->{siries_name}</h1>
    <h2>$stage_name->{$stage}阶段 第${group_number}组 比赛结果 @ $date</h2>
    <p>
        <table>
            <tr><th>参赛人员</th><th>比分</th><th>参考积分</th><th>原积分</th><th>新积分</th><th>积分变动</th></tr>
            <tr><td>$names{$userid1}</td><td>$win1</td><td>$ref1</td><td>$point1</td><td>$new_point1</td><td>$diff1</td></tr>
            <tr><td>$names{$userid2}</td><td>$win2</td><td>$ref2</td><td>$point2</td><td>$new_point2</td><td>$diff2</td></tr>
        </table>
    </p>
    <p></p>
    <p>各局详细比分</p>
    <p>
        <table>
            <tr><th>$names{$userid1}</th><th>$names{$userid2}</th></tr>
            $game_details
        </table>
    </p>
    <p>$comment</p>
    <p> 请访问<a href='$https://$settings::servername$ENV{REQUEST_URI}'>$settings::title</a>获得其它信息</p>
    </body>
EOT
        if ( $settings::mail =~ /@/ ) {
            @to = split(/[,;]/, $settings::mail);
            $cc = '';
        }
        send_html_email(join(', ', @to), $cc, "新比赛结果出来了 $names{$userid1} V.S. $names{$userid2} $win1:$win2", $content);
    }

    { success => 1, msg => "$userid1: $point1 => $new_point1, $userid2: $point2 => $new_point2" };
}

sub getMatch() {
    my $match_id = get_param('match_id') || -1;
    return { success=>1, match=>[] } if $match_id < 0;
    my @match = $db->exec('SELECT m.match_id, m.siries_id, m.date, m.comment FROM MATCHES AS m, MATCH_DETAILS AS d WHERE m.match_id=d.match_id AND m.match_id=? AND d.win=?;', [$match_id, 1], 1);
    # FIXME
    my @games = $db->exec('SELECT g.game_id, g.game_number, g.userid, g.win, g.lose FROM GAMES AS g, MATCHES AS m WHERE m.match_id=g.match_id AND m.match_id=?;', [$match_id], 1);
    { success=>1, match=>\@match };
}

sub getMatches() {
    my @matches = $db->exec('SELECT m.match_id, m.stage, m.group_number, m.date, m.comment, d.point_ref, d.point_before, d.point_after, ' .
                         'd.userid, d.win, d.lose, d.game_win, d.game_lose, u.userid, u.name || ", " || u.cn_name || ", " || u.nick_name as full_name, s.siries_name ' .
                         'FROM MATCHES AS m, MATCH_DETAILS AS d, SERIES AS s, USERS AS u ' .
                         'WHERE m.match_id=d.match_id AND m.siries_id=s.siries_id AND d.userid=u.userid;', undef, 1);
    return { success => 0, msg => $db->{errstr} } if $db->{error};
    my @games = $db->exec('SELECT * FROM GAMES WHERE win > lose;', undef, 1);
    return { success => 0, msg => $db->{errstr} } if $db->{error};
    my %games; # { match_id => [{game_id => 1, win => 11, lose => 7, userid => user1}, {...}] }
    foreach (@games) {
        my %val = %$_{qw(game_number userid game_id win lose)};
        push $games{$_->{match_id}}->@*, \%val;
    }
    # combine the 2 records from details into 1
    my (%win, %lose);
    foreach (@matches) {
        if ( $_->{win} ) {
            $win{$_->{match_id}} = $_;
        } else {
            $lose{$_->{match_id}} = $_;
        }
    }
    foreach my $match_id ( keys %win ) {
        $win{$match_id}->{full_name2} = $lose{$match_id}->{full_name};
        $win{$match_id}->{point_before2} = $lose{$match_id}->{point_before};
        $win{$match_id}->{point_after2} = $lose{$match_id}->{point_after};
        $win{$match_id}->{point_ref2} = $lose{$match_id}->{point_ref};
        my $game = $games{$match_id};
        # change all the games point to the match win user's view
        foreach ( $game->@* ) {
            next if $_->{userid} eq $win{$match_id}->{userid};
            ( $_->{win},  $_->{lose}, $_->{userid} ) = ( $_->{lose}, $_->{win}, $win{$match_id}->{userid} );
        }
        $win{$match_id}->{games} = [ sort { $a->{game_number} <=> $b->{game_number} } $game->@* ];
    }
    @matches = sort { $b->{date} cmp $a->{date} || $b->{match_id} <=> $a->{match_id} } values %win;
    { success => !$db->{error}, matches => \@matches, msg => $db->{errstr} };
}

sub editSeries() {
    return { success=>0, msg=>"只有管理员可以编辑系列赛" } if !isAdmin($userid);
    my $siries_name = get_param('siries_name', '');
    return { success=>0, msg=>"名字不能为空" } if $siries_name eq '';
    my $siries_id = get_param('siries_id') || -1;
    return { success=>0, msg=>"自由约战是系统比赛，不可更改" } if $siries_id == 1;
    my $number_of_groups = get_param('number_of_groups') || 1;
    my $group_outlets = get_param('group_outlets') || 1;
    my $top_n = get_param('top_n') || 1;
    my $stage = get_param('stage') || 0;

    return { success=>0, msg=>"输入值不对" } if $number_of_groups < 0 || $group_outlets < 0 || $top_n < 0 || $stage < 0 || $stage > STAGE_END;

    my $need_capture = ( $stage > 0 && $stage < STAGE_END ) ? 1 : 0; # 比赛开始或者进入下个阶段
    eval {
        $db->{dbh}->begin_work;
        if ( $siries_id > 0 ) {
            my @old_stage = $db->exec('SELECT stage from SERIES WHERE siries_id=?;', [$siries_id], 1, 0);
            my $old = ( !$db->{err} && scalar @old_stage == 1 && defined $old_stage[0]->{stage} ) ? $old_stage[0]->{stage} : -1;
            $db->exec('UPDATE SERIES set siries_name=?,number_of_groups=?,group_outlets=?,top_n=?,stage=? where siries_id=?;',
                      [$siries_name, $number_of_groups, $group_outlets, $top_n, $stage, $siries_id], 0, 0);
            $need_capture &&= ( $old < $stage ) ? 1 : 0; # eg, 报名结束，进入循环赛
        } else {
            $db->exec('INSERT INTO SERIES(siries_name,number_of_groups,group_outlets,top_n,stage) VALUES(?,?,?,?,?);',
                      [$siries_name, $number_of_groups, $group_outlets, $top_n, $stage], 2, 0);
            $siries_id = $db->{last_insert_id};
        }
        if ( $need_capture ) {
            # Get all the users from last stage
            my @users = $db->exec("SELECT userid FROM SERIES_USERS WHERE siries_id=? AND stage=?;", [$siries_id, $stage -1], 1, 0);
            my $point = getBasePoint($siries_id, 'users'); # 进入下一阶段，分数以USERS表格中的最新值为新的基准
            foreach my $uid ( map{; $_->{userid}; } @users ) {
                # 如果这一阶段已经有了分数，那么就不跟新了，这是为了处理'返回报名又重新比赛'
                $db->exec('INSERT OR IGNORE INTO SERIES_USERS(siries_id, stage, userid, original_point, group_number) VALUES(?,?,?,?,?)',
                          [$siries_id, $stage, $uid, $point->{$uid} // 0, 1], 0, 0);
            }
        }
        $db->{dbh}->commit();
    };
    my $success = !$db->{err};
    if ($@) {
        $db->{dbh}->rollback();
        $success = 0;
    }

    { success => $success, msg => $db->{errstr} };
}

sub getSeries() {
    my $siries_id = get_param('siries_id') || -1;
    my $ongoing = get_param('ongoing', '');
    my @series;
    my $base = 'SELECT siries_id, siries_name, number_of_groups, group_outlets, top_n, stage FROM SERIES';
    if ( $siries_id > 0 ) {
        @series = $db->exec("$base WHERE siries_id=?;", [$siries_id], 1);
    } elsif ( $ongoing ) {
        @series = $db->exec("$base WHERE stage<?;", [STAGE_END], 1);
    } else {
        @series = $db->exec("$base;", undef, 1);
        if ( !$db->{error} ) {
            my @count = $db->exec('SELECT siries_id, stage, count(*) AS enroll FROM SERIES_USERS GROUP BY siries_id, stage', undef, 1);
            if ( !$db->{error} ) {
                my %c;
                foreach (@count) {
                    $c{$_->{siries_id}}->{$_->{stage}} = $_->{enroll};
                }
                foreach ( @series ) {
                    my $all = $c{$_->{siries_id}} // {};
                    $_->{enroll} = $all->{0} // 0;
                    $_->{count} = $all->{$_->{stage}} // 0;
                }
            }
        };
    }
    { success=>!$db->{error}, series=>\@series };
}

# NOTE: no transcation mode for this sub
sub getBasePoint($siries_id, $priorty='users') {
    my %point; # { usera => point }
    my @points = $db->exec("SELECT userid, original_point AS point FROM SERIES_USERS WHERE siries_id=? ORDER BY stage DESC;", [$siries_id], 1, 0);
    foreach (@points) {
        $point{$_->{userid}} = $_->{point} if !defined $point{$_->{userid}} && $_->{point}; # get the point from latest stage
    }
    @points = $db->exec("SELECT userid, point FROM USERS;", undef, 1, 0);
    foreach (@points) {
        $point{$_->{userid}} = $_->{point} if ( $priorty eq 'users' || !defined $point{$_->{userid}} ) && $_->{point};
    }
    \%point;
}

sub editSeriesUser {
    my $siries_id = get_param('siries_id') || -1;
    my $stage = get_param('stage') // -1;
    return { success=>0, msg=>"系列赛ID不正确" } if $siries_id <= 0 || $stage < 0;;
    my $users = {map {; $_ => 1 } get_multi_param('users', [])->@*};
    my $old_users = {map {; $_->{userid} => 1 } $db->exec('SELECT userid FROM SERIES_USERS WHERE siries_id=? AND stage=?', [$siries_id, $stage], 1)};
    my (@add_users, @delete_users);
    foreach ( keys $old_users->%* ) {
        push @delete_users, $_ if !exists $users->{$_};
    }
    return { success => 0, msg => "为了防止误操作，每次最多删除两个报名人员" } if scalar @delete_users > 2;
    foreach ( keys $users->%* ) {
        push @add_users, $_ if !exists $old_users->{$_};
    }
    if ( !isAdmin() && ( scalar @add_users > 1 || scalar @delete_users > 1
                         || ( scalar @add_users == 1 && $add_users[0] != $userid ) || ( scalar @delete_users == 1 && $delete_users[0] != $userid ) ) ) {
        return { success => 0, msg => '不能修改别人'  };
    }
    eval {
        $db->{dbh}->begin_work;
        foreach ( @delete_users ) {
            $db->exec('DELETE FROM SERIES_USERS WHERE userid=? AND siries_id=? AND stage=?', [$_, $siries_id, $stage], 0, 0); # delete from all stages
        }
        my $basePoint = getBasePoint($siries_id, 'users');
        foreach ( @add_users ) {
            $db->exec( "INSERT OR IGNORE INTO SERIES_USERS(siries_id, stage, userid, original_point) VALUES(?,?,?,?);", [$siries_id, $stage, $_, $basePoint->{$_} // DEFAULT_POINT ], 0, 0 );
        }
        $db->{dbh}->commit();
    };
    if ( $@ ) {
        $db->{dbh}->rollback();
        return { success => 0, msg => $db->{errstr} };
    }
    { success => 1, msg=>"增加了" . scalar @add_users . "个人员，删除了" . scalar @delete_users . "个人员" }
}

sub getUserList() {
    # TODO, filter
    my @val = $db->exec('SELECT name || ", " || cn_name || ", " || nick_name as full_name, * FROM USERS WHERE logintype<=? ORDER BY userid ASC;', [1], 1);
    { success=>!$db->{error}, users=>\@val };
}

sub main_page($q) {
    print "<script type='text/javascript'>//<![CDATA[\n" .
        "Ext.onReady(TT.app.main_page, TT.app);" .
        "\n//]]></script>\n";
    print $q->end_html();
}

sub printheader($q) {
    print $q->header( -charset=>'utf-8',
                      -expires=>'now',
                    );
    my $js_settings = "var title = '$settings::title';\nvar extjs_root = '$extjs';\n";
    print $q->start_html(-title=>$settings::title,
                         -encoding=>'utf-8',
                         -author=>'Opera.Wang@Synopsys.com',
                         -head=>Link({-rel=>'SHORTCUT ICON',-type=>'image/x-icon',-href=>"$imgd/tt.png"}),
                         -style=>{-src => ["$extjs/resources/css/ext-all.css",
                                           "tt.css",
                                          ]
                                 },
                         -script=>[{-src=>"$extjs/adapter/ext/ext-base.js"},
                                   {-src=>"$extjs/ext-all" . ( $settings::debug ? "-debug" : "" ) . ".js"},
                                   {-code=>$js_settings},
                                   {-src=>"tt.js"},
                                  ],
                         -meta=>{'keywords'=>'Table Tennis',
                                },
                         -dtd=>['-//W3C//DTD HTML 4.01 Transitional//EN', 'http://www.w3.org/TR/html4/loose.dtd'],
                        );
}

sub check_server($q) {
    return if !defined $ENV{SERVER_NAME} || $ENV{SERVER_NAME} eq $settings::servername;
    printheader($q);
    print "Please visit $settings::servername$ENV{REQUEST_URI}\n";
    print $q->end_html();
    exit 1;
}

sub main() {
    $userid = $ENV{REMOTE_USER} // $ENV{USER}; # web use REMTOE_USER, console test use USER
    $q = new CGI;
    check_server($q);
    $db = db->new();
    my $action = $q->param('action') || '';
    my @valid_actions = qw(getGeneralInfo getUserList getUserInfo editUser getPointList isAdmin getMatch getMatches editMatch getSeries editSeries editSeriesUser);
    if ( $action ) {
        # we already use utf8, perl will use unicode internally, so JSON shouldn't care about it
        # https://stackoverflow.com/questions/10708297/perl-convert-a-string-to-utf-8-for-json-decode
        # JSON->new->utf8(1)->decode, input must be UTF-8
        # JSON->new->utf8(0)->decode, input must be Unicode chars
        my $json = JSON::XS->new->utf8(0)->relaxed->allow_nonref;
        $json = $json->pretty(1) if -t STDIN;
        print "Content-Type: text/html; charset=utf-8\n\n";
        if ( $action ~~ @valid_actions ) {
            no strict 'refs';
            print $json->encode(&$action());
        } else {
            print $json->encode({success => 0, msg => 'unknown action'});
        }
    } else {
        printheader($q);
        main_page($q);
    }
    $db->disconnect();
    exit 0;
}

main();

