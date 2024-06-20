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
use Scalar::Util;
use JSON::XS;
use Time::Piece;
use Time::Seconds;
use Net::LDAP;
use List::Util qw(sum0);

use constant {
    DEFAULT_POINT => 1600,
    STAGE_END => 100,
    ADMIN_ACCOUNT => 0,
    NORMAL_ACCOUNT => 1,
    DISABLED_ACCOUNT => 2,
};
my $stage_name = { 0 => '报名', 1 => '循环赛', 2 => '淘汰赛', 3 => '自由赛', &STAGE_END() => '结束' };

use settings;
eval {
    use site_settings;
};
use db;

my $imgd = 'etc';
my $jquery = 'https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1';
my $extjs = 'https://cdnjs.cloudflare.com/ajax/libs/extjs/3.4.1-1';
my $echarts = 'https://cdnjs.cloudflare.com/ajax/libs/echarts/5.1.2';
my $sprintf = 'https://cdnjs.cloudflare.com/ajax/libs/sprintf/1.1.2';
# for bracket view, use either https://github.com/teijo/jquery-bracket or https://github.com/sbachinin/bracketry
my $bracket = 'https://cdnjs.cloudflare.com/ajax/libs/jquery-bracket/0.11.0';

my $userid = '';
my ($q,$db);
my $perPage = 40;

# https://perldoc.perl.org/Encode/MIME/Header.html
# http://hansekbrand.se/code/UTF8-emails.html
sub send_html_email($to, $cc, $subject, $msg) {
    my $from = $ENV{SERVER_ADMIN} // $ENV{USER} // 'unknown@test.com';
    $from = $from . '@test.com' if $from !~ /@/; # send may fail but won't warning
    my %mail = (
        From                       => encode("MIME-Header", $settings::title) . "<$from>",
        To                         => $to,
        Cc                         => $cc,
        Subject                    => encode("MIME-Header", $subject),
        Message                    => encode('utf8', $msg),
        'content-type'             => 'text/html; charset="utf-8"',
        'Auto-Submitted'           => 'auto-generated', # https://tools.ietf.org/html/rfc3834
        'X-Auto-Response-Suppress' => "All",
        'reply-to'                 => "$to,$cc",
    );
    sendmail(%mail) or print STDERR "Sendmail: $Mail::Sendmail::error\n";
}
sub getUserInfo($uid = undef) {
    $uid //= lc($q->param('userid', ''));
    my $fail = {success=>0, user=>[{}]};

    # In DB?
    my @res = $db->exec( "SELECT userid, name, cn_name, nick_name, email, logintype, gender, point FROM USERS WHERE USERID=?", [$uid], 1 );
    return $fail if scalar @res > 1;
    return {success=>1, db=>1, user=>[$res[0]]} if scalar @res == 1;

    # Try LDAP if not found in db
    my ($ldap, $mesg, $email, $name, $employeeNumber);
    $ldap = Net::LDAP->new( $settings::ldapserver ) or do { print "$@"; return $fail; };
    if ( $settings::bindDN && $settings::bindPassword ) {
        $mesg = $ldap->bind($settings::bindDN, password => $settings::bindPassword);
    } else {
        $mesg = $ldap->bind;
    }
    $mesg = $ldap->search(
                           base   => $settings::baseDN,
                           filter => "(uid=" . $uid .")",
                           attrs  => [$settings::name, $settings::email, $settings::employeeNumber, 'cn']
                         );
    $mesg->code && do { print $mesg->error; return $fail };
    return $fail if $mesg->count != 1;

    foreach my $entry ($mesg->entries) {
        $name = ($entry->get_value($settings::name))[0] || ($entry->get_value('cn'))[0] || $uid;
        $name =~ s/\s*\(External\)//i; # remove (External) from name
        $email = ($entry->get_value($settings::email))[0] || '';
        $employeeNumber = ($entry->get_value($settings::employeeNumber))[0] || '';
    }
    $mesg = $ldap->unbind;

    { success=>1, db=>0, user=>[{userid=>$uid, name => $name, email => $email, employeeNumber => $employeeNumber, logintype => NORMAL_ACCOUNT, gender=> '未知', point => 0}] };
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
    return !$val[0]->{logintype} if scalar @val != 0;
    # or there's no admin yet
    my @anyone = $db->exec('SELECT count(logintype) AS c FROM USERS WHERE logintype=?;', [ADMIN_ACCOUNT], 1);
    return 0 if $db->{err} || scalar @anyone == 0;
    !$anyone[0]->{c};
}

sub editUser() {
    my $id = lc(get_param('userid')//'');
    return { success=>0, msg=>'Invalid input' } if !$id;
    my $nick_name = get_param('nick_name', '');
    my $cn_name = get_param('cn_name', '');
    my $logintype = get_param('logintype', NORMAL_ACCOUNT);
    my $gender = get_param('gender', 'Male');
    my $point = get_param('point') || 0;

    my $userInfo = getUserInfo($id);
    my $success = $userInfo->{success};
    my $old_point = $userInfo->{user}[0]{point} || 0;

    my $admin = isAdmin($userid);
    # check permissions, only admin can set another as admin/change point directly
    if ( !$admin ) {
        return { success=>0, msg=>"Permission denied, Can't change ${id}'s value" } if $id ne $userid;
        return { success=>0, msg=>"Permission denied, Can't set $id as admin" } if $logintype == ADMIN_ACCOUNT;
        return { success=>0, msg=>"Permission denied, Can't set ${id}'s point" } if $point > 0 && $point != $old_point;
    }

    if ( $success ) {
        $db->exec("INSERT INTO USERS(userid,name,email,employeeNumber,logintype,gender,point) VALUES(?,?,?,?,?,?,?) ON CONFLICT(userid) DO NOTHING;",
            [$id, @{$userInfo->{user}[0]}{qw(name email employeeNumber logintype gender point)}], 0 ) if !$userInfo->{db};
        $db->exec('UPDATE USERS set nick_name=?,cn_name=?,logintype=?,gender=? where userid=?;', [$nick_name, $cn_name, $logintype, $gender, $id], 0) if !$db->{err};
        $success = 0 if $db->{err};
    }

    if ( $success && $point > 0 ) {
        $db->exec('UPDATE USERS set point=? where userid=?;', [$point, $id], 0);
        $success = 0 if $db->{err};
    }

    { success=>$success, msg=>$db->{errstr} };
}

# check if all users are still active/inactive in LDAP and update the user list
sub checkAllUsers() {
    return { success=>0, msg=>'管理员专用' } if !isAdmin();
    my @db_users = $db->exec('SELECT userid,logintype FROM USERS;', undef, 1);
    return { success=>0, msg=>$db->{errstr} } if $db->{err};
    my %db_users = map {; $_->{userid} => $_->{logintype} } @db_users; # { userid => logintype }

    my $ldap = Net::LDAP->new( $settings::ldapserver ) or do { print "$@"; return { success=>0, msg=>"LDAP connect error" }; };
    my $mesg;
    if ( $settings::bindDN && $settings::bindPassword ) {
        $mesg = $ldap->bind($settings::bindDN, password => $settings::bindPassword);
    } else {
        $mesg = $ldap->bind;
    }
    $mesg = $ldap->search(
                           base   => $settings::baseDN,
                           filter => "(|" . join('', map {;"(uid=$_)"} keys %db_users) . ")", # (|(uid=1)(uid=2))
                           attrs  => ['uid'],
                         );
    $mesg->code && do { print $mesg->error; return { success=>0, msg=>"LDAP search error" } };
    my %users;
    foreach my $entry ($mesg->entries) {
        my $uid = $entry->get_value('uid');
        my $disabled = $entry->dn() =~ /Disabled/i ? 1 : 0; # CN=uid,OU=Disabled Accounts,DC=internal,DC=company,DC=com
        $users{$uid} = $disabled;
    }
    $mesg = $ldap->unbind;

    my $success = 1;
    my $updated = [];
    foreach my $uid ( keys %db_users ) {
        if ( ( !exists $users{$uid} || $users{$uid} == 1 ) && $db_users{$uid} != DISABLED_ACCOUNT ) {
            $db->exec('UPDATE USERS set logintype=? where userid=?;', [DISABLED_ACCOUNT, $uid], 0);
            $success = 0 if $db->{err};
            push $updated->@*, "$uid => 停用用户" if $success;
        } elsif ( exists $users{$uid} && $users{$uid} == 0 && $db_users{$uid} == DISABLED_ACCOUNT ) {
            $db->exec('UPDATE USERS set logintype=? where userid=?;', [NORMAL_ACCOUNT, $uid], 0);
            $success = 0 if $db->{err};
            push $updated->@*, "$uid => 普通用户" if $success;
        }
    }
    { success=>$success, msg=>join(', ', $updated->@*) };
}

sub getPointList() {
    my $siries_id = get_param('siries_id') || 0;
    my $stage = get_param('stage') || 0;
    my $fail = { success=>0, users => [] };
    my @users = $db->exec('SELECT userid,name,nick_name,employeeNumber,cn_name,gender,point,email FROM USERS WHERE logintype<=? ORDER BY userid ASC;', [1], 1);
    return $fail if $db->{err};
    my @win = $db->exec('SELECT sum(win) AS win, sum(lose) AS lose, sum(game_win) AS game_win, sum(game_lose) AS game_lose, userid FROM MATCH_DETAILS GROUP BY userid;', undef, 1);
    return $fail if $db->{err};
    my $user = {}; # { id => { win => 0, fail => 1 } }
    foreach my $detail (@win) {
        foreach (qw(win lose game_win game_lose)) {
            $user->{$detail->{userid}}->{$_} = $detail->{$_};
        }
    }
    if ( $siries_id && $stage >= 0 ) {
        my @siries = $db->exec('SELECT userid,group_number FROM SERIES_USERS WHERE siries_id=? AND stage=?;', [$siries_id, $stage], 1);
        return $fail if $db->{err};
        foreach (@siries) {
            $user->{$_->{userid}}->{siries} = 1;
            $user->{$_->{userid}}->{group} = $_->{group_number};
        }
    }
    foreach my $p ( qw(win lose game_win game_lose siries group) ) {
        foreach (@users) {
            $_->{$p} = $user->{$_->{userid}}->{$p} // 0;
        }
    }
    { success=>1, users=>\@users };
}

sub getPointHistory() {
    my $id = lc(get_param('userid') // '');
    return { success=>0, points=>[], msg=> 'empty id' } if $id eq '';
    my @points = $db->exec('SELECT match_details.*,matches.date,matches.stage,matches.group_number,series.siries_name,u1.cn_name AS name1,u2.cn_name AS name2 ' .
        'FROM match_details,matches,series,users u1,users u2 WHERE match_details.match_id=matches.match_id AND matches.siries_id=series.siries_id ' .
        'AND u1.userid=match_details.userid AND u2.userid=match_details.userid2 AND match_details.userid=? ORDER BY date,match_id;', [$id], 1);
    return { success => 0, msg => '找不到历史分数', points=>[] } if $db->{err} || scalar @points == 0;
    { success=>1, points=>\@points };
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
    my $group_number = get_param('group') || 1;
    my $date = get_param('date', ''); # 2019-08-17
    my $userid1 = get_param('userid1', '');
    my $userid2 = get_param('userid2', '');
    return { success => 0, msg => '输入信息不正确' } if $siries_id < 0 || !$date || !$userid1 || !$userid2 || $userid1 eq $userid2;
    my @series = $db->exec('SELECT siries_id, siries_name, stage FROM SERIES where siries_id=? and stage<?;', [$siries_id, STAGE_END], 1);
    return { success => 0, msg => '找不到合适的比赛项目' } if $db->{err} || scalar @series != 1;
    my $stage = $series[0]->{stage};
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
    my $waive = get_param('waive', 'off');
    $waive = ( $waive eq 'on' ) ? 1 : 0;

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
    my ( $waive1, $waive2 ) = ('', '');
    if ( $waive ) {
        if ( $win ) {
            $waive2 = "(弃权)";
        } else {
            $waive1 = "(弃权)";
        }
    }

    # update DB using transcation
    eval {
        $db->{dbh}->begin_work;
        $db->exec("INSERT INTO MATCHES(siries_id, stage, group_number, date, comment) VALUES(?,?,?,?,?);", [$siries_id, $stage, $group_number, $date, $comment], 2, 0);
        $match_id = $db->{last_insert_id};
        die "Invalid siries_id\n" if $match_id <= 0;
        $db->exec("INSERT INTO MATCH_DETAILS(match_id, userid, point_ref, point_before, point_after, win, lose, game_win, game_lose, userid2, waive) VALUES(?,?,?,?,?,?,?,?,?,?,?);",
                  [$match_id, $userid1, $ref1, $point1, $new_point1, $win, $lose, $win1, $win2, $userid2, $waive], 0, 0);
        $db->exec("INSERT INTO MATCH_DETAILS(match_id, userid, point_ref, point_before, point_after, win, lose, game_win, game_lose, userid2, waive) VALUES(?,?,?,?,?,?,?,?,?,?,?);",
                  [$match_id, $userid2, $ref2, $point2, $new_point2, $lose, $win, $win2, $win1, $userid1, $waive], 0, 0);
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
        if ( Scalar::Util::looks_like_number($settings::mail) && $settings::mail >= 2 ) { # CC admin
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
          h1 {
            line-height: 125%;
          }
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
    <body style="font-family: Segoe UI, Helvetica, Arial, 宋体, 微软雅黑, sans-serif">
    <h1>$series[0]->{siries_name}</h1>
    <h2>$stage_name->{$stage}阶段 第${group_number}组 比赛结果 @ $date</h2>
    <p>
        <table>
            <tr><th>参赛人员</th><th>比分</th><th>参考积分</th><th>原积分</th><th>新积分</th><th>积分变动</th></tr>
            <tr><td>$names{$userid1}</td><td>$win1$waive1</td><td>$ref1</td><td>$point1</td><td>$new_point1</td><td>$diff1</td></tr>
            <tr><td>$names{$userid2}</td><td>$win2$waive2</td><td>$ref2</td><td>$point2</td><td>$new_point2</td><td>$diff2</td></tr>
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
        if ( $settings::mail =~ /@/ ) { # if set the mail to email address, only send to him/her, for debug purpose
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

sub getMatches($siries_id = undef, $stage = undef, $group_number = undef) {
    my $id = lc(get_param('userid', ''));
    my (@filters, @inputs) = ((), ());
    if ( defined $siries_id ) {
        push @filters, 'siries_id';
        push @inputs, $siries_id;
    }
    if ( defined $stage ) {
        push @filters, 'stage';
        push @inputs, $stage;
    }
    if ( defined $group_number ) {
        push @filters, 'group_number';
        push @inputs, $group_number;
    }
    my $filter = join(' ', map{; "AND m.$_=?"} @filters); # "AND m.siries_id=? AND m.stage=? AND m.group_number=?"
    my $sql = 'SELECT m.match_id, m.stage, m.group_number, m.date, m.comment, d.point_ref, d.point_before, d.point_after, d.waive, ' .
              'd.userid, d.win, d.lose, d.game_win, d.game_lose, u.userid, u.name || ", " || u.cn_name || ", " || u.nick_name as full_name, s.siries_name ' .
              'FROM MATCHES AS m, MATCH_DETAILS AS d, SERIES AS s, USERS AS u ' .
              "WHERE m.match_id=d.match_id AND m.siries_id=s.siries_id AND d.userid=u.userid $filter;";
    my @matches = $db->exec($sql, \@inputs, 1);
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
        $win{$match_id}->{userid2} = $lose{$match_id}->{userid};
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
    @matches = grep { $_->{userid} eq $id || $_->{userid2} eq $id } @matches if $id;
    { success => !$db->{error}, matches => \@matches, msg => $db->{errstr} };
}

sub set_compare_result($levels, $cross_detail) {
    my @lvs = sort { $b <=> $a } keys $levels->%*; # (30, 29, 18, ...)
    foreach my $level1 ( @lvs ) {
        my @users = $levels->{$level1}->@*;
        # if more than 1 users have same score, then compare again
        compare_users(\@users, $cross_detail) if scalar @users >= 2;
        foreach my $level2 ( @lvs ) {
            next if $level2 >= $level1;
            foreach my $users1 ( @users ) {
                foreach my $users2 ( $levels->{$level2}->@* ) {
                    $cross_detail->{$users1}->{$users2}->{sorting} = 1;
                    $cross_detail->{$users2}->{$users1}->{sorting} = -1;
                }
            }
        }
    }
}

# https://max.book118.com/html/2019/0319/6132102113002015.shtm
# 3.7.5.1在分组循环赛中，小组里每一成员应与组内所有其他成员进行比赛；胜一场得2分，输一场得1分，未出场比赛或未完成比赛输的场次得0分，小组名次应根据所获得的场次分数决定。
# 3.7.5.2如果小组的两个或更多的成员得分数相同，他们有关的名次应按他们相互之间比赛的成绩决定。首先计算他们之间获得的场次分数，再根据需要计算个人比赛场次(团体赛时)、局和分的胜负比率，直至算出名次为止。
# 3.7.5.3如果在任何阶段已经决定出一个或更多小组成员的名次后，而其他小组成员仍然得分相同，为决定相同分数成员的名次，根据3.7.5.1和3.7.5.2条程序继续计算时，应将已决定出名次的小组成员的比赛成绩删除。
sub compare_users($users, $cross_detail) {
    my (%scores, %compare_games, %compare_points);
    while (my ($user1, $crosses) = each( $cross_detail->%* )) {
        #$crosses userid2 => { win => 1, game_win => $m->{game_win}, game_lose => $m->{game_lose}, point_win => $point_win, point_lose => $point_lose, waive => $waive };
        next unless $user1 ~~ $users;
        while (my ($user2, $cross) = each( $crosses->%* )) {
            next if !defined $cross->{win} || $cross->{win} == 0; # only check win half
            next unless $user2 ~~ $users;
            $scores{$user1} += 2;
            $scores{$user2} += ( $cross->{waive} ? 0 : 1 );
            $compare_games{$user1}->{win} += $cross->{game_win};
            $compare_games{$user1}->{lose} += $cross->{game_lose};
            $compare_games{$user2}->{lose} += $cross->{game_win};
            $compare_games{$user2}->{win} += $cross->{game_lose};
            $compare_points{$user1}->{win} += $cross->{point_win};
            $compare_points{$user1}->{lose} += $cross->{point_lose};
            $compare_points{$user2}->{lose} += $cross->{point_win};
            $compare_points{$user2}->{win} += $cross->{point_lose};
        }
    }
    my (%score_level, %games_level, %points_level); # ( 30 => [use1, user2], ... )
    my $e = 0.0000001;
    foreach ( $users->@* ) {
        push $score_level{$scores{$_} || 0}->@*, $_;
        my $games_ratio = ( $compare_games{$_}->{win} || 0 ) / ( $compare_games{$_}->{lose} || $e );
        push $games_level{$games_ratio}->@*, $_;
        my $points_ratio = ( $compare_points{$_}->{win} || 0 ) / ( $compare_points{$_}->{lose} || $e );
        push $points_level{$points_ratio}->@*, $_;
    }
    #print STDERR Dumper($users, \%scores, \%compare_games, \%compare_points, \%score_level, \%games_level, \%points_level);
    if ( scalar keys %score_level > 1 ) {
        set_compare_result(\%score_level, $cross_detail);
    } elsif ( scalar keys %games_level > 1 ) {
        set_compare_result(\%games_level, $cross_detail);
    } elsif ( scalar keys %points_level > 1 ) {
        set_compare_result(\%points_level, $cross_detail);
    }
}

sub getSeriesMatchGroups() {
    my $siries_id = get_param('siries_id') || -1;
    return { success=>0, msg=>"输入无效" } if $siries_id == -1;
    my @groups = $db->exec('SELECT siries_id,stage,group_number FROM matches WHERE siries_id=? GROUP BY siries_id,stage,group_number ORDER BY stage ASC;', [$siries_id], 1, 0);
    return { success=>!$db->{error}, msg => $db->{errstr}, groups =>\@groups } if $db->{error};
    # add more from all 循环赛 which might no match yet
    my %g = ();
    foreach ( @groups ) {
        $g{$_->{siries_id}}->{$_->{stage}}->{$_->{group_number}} = 1;
    }
    my @more = $db->exec('SELECT siries_id,stage,group_number FROM SERIES_USERS WHERE siries_id=? AND stage=? GROUP BY siries_id,stage,group_number ORDER BY stage ASC;', [$siries_id, 1], 1, 0);
    foreach ( @more ) {
        push @groups, $_ if !exists $g{$_->{siries_id}}->{$_->{stage}}->{$_->{group_number}};
    }
    { success=>!$db->{error}, msg => $db->{errstr}, groups =>\@groups };
}

sub getSeriesMatchBracket($matches, $users) {
    my %name;
    foreach ( $users->{users}->@* ) {
        $name{$_->{userid}} = $_;
    }
    # 1st sort the matches by match_id
    # then group the mathces into different rounds by scaning all the participants
    # if the participants are not in the same round, then add it to the current round
    # if found one participants already in the current round, then add the new one to the next round

    my @sorted = sort { $a->{match_id} <=> $b->{match_id} } $matches->@*;
    my @rounds; # ( [match1, match2,...), (match3, match4), ... )
    my %round_participants; # { 0 => { userid1 => 1, userid2 => 1 }, 1 => { userid1 => 1, userid4 => 1 }, ... }
    my $round = 0;
    foreach my $m ( @sorted ) {
        $m->{game} = join(',', map {; "$_->{win}:$_->{lose}" } $m->{games}->@*);
        my $found = 0;
        foreach my $p ( $m->{userid}, $m->{userid2} ) {
            if ( exists $round_participants{$round}->{$p} ) {
                $round++;
                $found = 1;
                last;
            }
        }
        $round_participants{$round}->{$m->{userid}} = 1;
        $round_participants{$round}->{$m->{userid2}} = 1;
        push $rounds[$round]->@*, $m;
    }

    # if the final round has bronze medal match, then it should be last element in the final round
    if ( 2 ** scalar @rounds == scalar keys $round_participants{0}->%* && scalar $rounds[-1]->@* == 2 ) {
        # check the previous round for is the winner is the same in the last element
        foreach my $m ( $rounds[-2]->@* ) {
            if ( $m->{userid} eq $rounds[-1]->[1]->{userid} ) {
                $rounds[-1] = [ $rounds[-1]->[1], $rounds[-1]->[0] ];
                last;
            }
        }

    }

    # 2nd, sort the matches in each round by the participants in next round
    # eg, if A and B plays in round 2, then A and B should be in the same (half) zone in round 1
    # the final round may contains match for bronze medal and gold medal

    my $total_rounds = scalar @rounds;
    foreach ( my $r = $total_rounds-1; $r >= 0; $r-- ) {
        next if $r == $total_rounds-1;
        my $sort_priority = {}; # { userid1 => 0, userid2 => 1, ... }
        my $priority = 0;
        foreach my $m ( $rounds[$r+1]->@* ) { # based on next round
            $sort_priority->{$m->{userid}} = $priority;
            $sort_priority->{$m->{userid2}} = $priority;
            $priority++;
        }
        $rounds[$r] = [ sort { $sort_priority->{$a->{userid}} <=> $sort_priority->{$b->{userid}} } $rounds[$r]->@* ];
    }

    # 3rd, draw the bracket
    # { "teams": [              // Matchups
    #     ["Team 1", "Team 2"], // First match
    #     ["Team 3", "Team 4"]  // Second match
    # ],
    # "results": [              // List of brackets (single elimination, so only one bracket)
    #   [                       // List of rounds in bracket
    #     [                     // First round in this bracket
    #       [1, 2, "details"],  // Team 1 vs Team 2
    #       [3, 4, "details"],  // Team 3 vs Team 4
    #     ],
    #     [                     // Second (final) round in single elimination bracket
    #       [5, 6],             // Match for first place, so it's team 2 vs team 4
    #       [7, 8]              // Match for 3rd place
    #] ],
    #] }

    my @teams; # ( [{userid, name, ...}, id2 => {userid, name,...}, ... ), only need from round 0
    my @results; # ( [ [ [1, 2, "details"], [3, 4, "details"] ], [ [5, 6], [7, 8] ] ], ... )
    my $pariticpants_order = {}; # { userid1 => 1, userid2 => 2, ... }
    my $order = 0;
    foreach my $m ( $rounds[0]->@* ) {
        push @teams, [ $name{$m->{userid}}, $name{$m->{userid2}} ];
        $pariticpants_order->{$m->{userid}} = $order++;
        $pariticpants_order->{$m->{userid2}} = $order++;
    }
    foreach my $r ( 0..$total_rounds-1 ) {
        my @round;
        foreach my $m ( $rounds[$r]->@* ) {
            # $m is winners' view of the match
            my $user1_win = $pariticpants_order->{$m->{userid}} < $pariticpants_order->{$m->{userid2}} ? 1 : 0;
            push @round, [ $user1_win ? $m->{game_win} : $m->{game_lose}, $user1_win ? $m->{game_lose} : $m->{game_win}, $m ];
        }
        push @results, [ @round ];
    }
    { success=>1, metaData=>{root=>'bracket', fields=>['teams']}, bracket => {teams=>\@teams, results=>\@results} };
}

sub getSeriesMatch() {
    my $siries_id = get_param('siries_id') || -1;
    return { success=>0, msg=>"输入无效" } if $siries_id == -1;
    my $stage = get_param('stage') || 1;
    my $group_number = get_param('group_number') || 1;
    my @userids = $db->exec('SELECT userid from SERIES_USERS WHERE siries_id=? AND stage=? AND group_number=?;', [$siries_id, $stage, $group_number], 1, 0);
    return { success=>0, msg=> $db->{errstr} } if $db->{err};
    my $data = getMatches($siries_id, $stage, $group_number);
    return $data if !$data->{success};
    my $userlist = getUserList();
    return $userlist if !$userlist->{success};
    my $matches = $data->{matches}; # [ { userid, userid2, win, lose, waive, games => [win, lose, game_number, game_id, userid] }, ... ]
    return getSeriesMatchBracket($matches, $userlist) if $stage == 2;
    my %name;
    foreach ( $userlist->{users}->@* ) {
        $name{$_->{userid}} = $_->{cn_name};
    }
    # change to 2 dimension table
    my %cross; # { userid1 => { userid2 => { 'result' => '0:2', 'win' => 0, 'game' => '2019-08-21, 13:15, 7:11', 'match_id' => 26 }, userid3 => {} }, ... }
    my %cross_detail; # { userid1 => { userid2 => { sorting: undef, win: 1, game_win: 0, game_lose: 2, point_win: 23, point_lose: 33}, ...}, ... }
    my %score_detail; #
    foreach my $m ($matches->@*) {
        my @games = $m->{games}->@*;
        my $game = "$m->{date}, " . join(', ', map {; "$_->{win}:$_->{lose}" } @games);
        my $game2 = "$m->{date}, " . join(', ', map {; "$_->{lose}:$_->{win}" } @games);
        my $point_win = sum0( map {; $_->{win} } $m->{games}->@* );
        my $point_lose = sum0( map {; $_->{lose} } $m->{games}->@* );
        $cross{$m->{userid}}->{$m->{userid2}} = { win => 1, result => "$m->{game_win}:$m->{game_lose}", match_id => $m->{match_id}, waive => $m->{waive}, game => $game };
        $cross{$m->{userid2}}->{$m->{userid}} = { win => 0, result => "$m->{game_lose}:$m->{game_win}", match_id => $m->{match_id}, waive => $m->{waive}, game => $game2 };
        $cross_detail{$m->{userid}}->{$m->{userid2}} = { win => 1, game_win => $m->{game_win}, game_lose => $m->{game_lose}, point_win => $point_win, point_lose => $point_lose, waive => $m->{waive} };
        $cross_detail{$m->{userid2}}->{$m->{userid}} = { win => 0, game_lose => $m->{game_win}, game_win => $m->{game_lose}, point_win => $point_lose, point_lose => $point_win, waive => $m->{waive} };
        $score_detail{$m->{userid}}->{value} += 2;
        $score_detail{$m->{userid2}}->{value} += ( $m->{waive} ? 0 : 1 );
        $score_detail{$m->{userid}}->{win} += 1;
        $score_detail{$m->{userid2}}->{lose} += 1;
        $score_detail{$m->{userid}}->{total} += 1;
        $score_detail{$m->{userid2}}->{total} += 1;
        $score_detail{$m->{userid2}}->{waive} += 1 if $m->{waive};
        push @userids, { userid => $m->{userid} };
        push @userids, { userid => $m->{userid2} };
    }
    my @users = keys { map{; $_->{userid} => 1 } @userids }->%*;
    compare_users(\@users, \%cross_detail);
    # 1st sort by scores etc desc, then sort by userid asc
    my @sort_users = sort { $cross_detail{$b}->{$a}->{sorting} // $a cmp $b } @users;
    my @results; # ( {userid => 'a', 'a' => 'N/A', 'b' => '2:0', 'c' => '3:1', ... '_score' => 10}, ... )
    foreach my $u1 ( @sort_users ) {
        my %r = ( userid => $u1, _name => $name{$u1}, _score => $score_detail{$u1} );
        foreach my $u2 ( @sort_users ) {
            $r{$u2} = $cross{$u1}->{$u2} // ( $u1 eq $u2 ? '' : {} );
        }
        push @results, \%r;
    }
    my @columns = map {; { header =>  $name{$_}, dataIndex => $_, renderer => 'renderRatio' } } @sort_users;
    push @columns, { header =>  '分数', dataIndex => '_score', renderer => 'renderScore' };
    unshift @columns, { header => '姓名', dataIndex => '_name' };
    my %meta = ( root => 'results', id => 'userid', fields => [ map{; {name => $_->{dataIndex}} } @columns] );
    { success => 1, metaData => \%meta, columns => \@columns, results => \@results };
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
    my $links = get_param('links', '');
    my $date;
    foreach my $s ( keys $stage_name->%* ) {
        $date->{"start_$s"} = get_param("start_$s", '');
        $date->{"end_$s"} = get_param("end_$s", ''); # NOTE: we don't need end time for end stage
    }

    return { success=>0, msg=>"输入值不对" } if $number_of_groups < 0 || $group_outlets < 0 || $top_n < 0 || $stage < 0 || $stage > STAGE_END;

    my $need_capture = ( $stage > 0 && $stage < STAGE_END ) ? 1 : 0; # 比赛开始或者进入下个阶段
    eval {
        $db->{dbh}->begin_work;
        if ( $siries_id > 0 ) {
            my @old_stage = $db->exec('SELECT stage from SERIES WHERE siries_id=?;', [$siries_id], 1, 0);
            my $old = ( !$db->{err} && scalar @old_stage == 1 && defined $old_stage[0]->{stage} ) ? $old_stage[0]->{stage} : -1;
            $db->exec('UPDATE SERIES set siries_name=?,number_of_groups=?,group_outlets=?,top_n=?,stage=?,links=? where siries_id=?;',
                      [$siries_name, $number_of_groups, $group_outlets, $top_n, $stage, $links, $siries_id], 0, 0);
            $need_capture &&= ( $old < $stage ) ? 1 : 0; # eg, 报名结束，进入循环赛
        } else {
            $db->exec('INSERT INTO SERIES(siries_name,number_of_groups,group_outlets,top_n,stage,links) VALUES(?,?,?,?,?,?);',
                      [$siries_name, $number_of_groups, $group_outlets, $top_n, $stage, $links], 2, 0);
            $siries_id = $db->{last_insert_id};
        }
        foreach my $s ( keys $stage_name->%* ) {
            if ( $date->{"start_$s"} eq '' && $date->{"end_$s"} eq '' ) {
                $db->exec('DELETE FROM SERIES_DATE WHERE siries_id=? AND stage=?', [$siries_id, $s], 0, 0);
            } else {
                $db->exec('INSERT INTO SERIES_DATE(siries_id,stage,start,end) VALUES(?,?,?,?) ON CONFLICT(siries_id,stage) DO UPDATE SET start=?,end=?;',
                          [$siries_id, $s, $date->{"start_$s"},$date->{"end_$s"},$date->{"start_$s"},$date->{"end_$s"}], 1, 0);
            }
        }
        if ( $need_capture ) {
            # Get all the users from last stage
            my @users = $db->exec("SELECT userid, group_number FROM SERIES_USERS WHERE siries_id=? AND stage=?;", [$siries_id, $stage -1], 1, 0);
            my $point = getBasePoint($siries_id, 'users'); # 进入下一阶段，分数以USERS表格中的最新值为新的基准
            foreach my $user ( @users ) {
                my $uid = $user->{userid};
                my $group_number = $stage <= 1 ? $user->{group_number} : 1; # 循环赛阶段的组号不变，其它阶段都是1
                # 如果这一阶段已经有了分数，那么就不跟新了，这是为了处理'返回报名又重新比赛'
                $db->exec('INSERT OR IGNORE INTO SERIES_USERS(siries_id, stage, userid, original_point, group_number) VALUES(?,?,?,?,?)',
                          [$siries_id, $stage, $uid, $point->{$uid} // 0, $group_number], 0, 0);
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
    my $ongoing = get_param('filter', '') eq 'ongoing' ? 1 : 0;
    my @series;
    my $base = 'SELECT siries_id, siries_name, number_of_groups, group_outlets, top_n, stage, links FROM SERIES';
    if ( $siries_id > 0 ) { # 编辑系列赛
        @series = $db->exec("$base WHERE siries_id=?;", [$siries_id], 1);
        getSeriesDate(\@series);
    } elsif ( $ongoing ) { # 输入比赛结果时只显示正在进行的比赛
        @series = $db->exec("$base WHERE stage<?;", [STAGE_END], 1);
    } else { # 显示系列赛
        @series = $db->exec("$base;", undef, 1);
        if ( !$db->{error} ) {
            my @count = $db->exec('SELECT siries_id, stage, count(*) AS enroll FROM SERIES_USERS GROUP BY siries_id, stage', undef, 1);
            if ( !$db->{error} ) {
                my %c;
                foreach (@count) {
                    $c{$_->{siries_id}}->{$_->{stage}} = $_->{enroll};
                }
                foreach ( @series ) {
                    my $c = $c{$_->{siries_id}} // {};
                    $_->{enroll} = $c->{0} // 0;
                    $_->{count} = $c->{$_->{stage}} // 0;
                }
            }
            getSeriesDate(\@series);
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
    return { success=>0, msg=>"已经过了报名阶段" } if $stage > 0 && !isAdmin();
    my $users = {map {; my @g = split(/,/, $_, 2); $g[0] => $g[1] || 1  } get_multi_param('users', [])->@*}; # { userid => group_number }
    my $old_users = {map {; $_->{userid} =>  $_->{group_number}; } $db->exec('SELECT userid,group_number FROM SERIES_USERS WHERE siries_id=? AND stage=?', [$siries_id, $stage], 1)};
    my (@add_users, @delete_users, @changed_users);
    foreach ( keys $old_users->%* ) {
        push @delete_users, $_ if !exists $users->{$_};
    }
    return { success => 0, msg => "为了防止误操作，报名阶段每次最多删除两个报名人员" } if $stage <= 1 && scalar @delete_users > 2;
    foreach ( keys $users->%* ) {
        if ( !exists $old_users->{$_} ) {
            push @add_users, { id => $_, group => $users->{$_} };
        } elsif ( $users->{$_} != $old_users->{$_} ) {
            push @changed_users, { id => $_, group => $users->{$_} };
        }
    }
    if ( !isAdmin() && ( scalar @add_users > 1 || scalar @delete_users > 1 || scalar @changed_users > 1
                         || ( scalar @add_users == 1 && $add_users[0]->{id} != $userid )
                         || ( scalar @delete_users == 1 && $delete_users[0] != $userid )
                         || ( scalar @changed_users == 1 && $changed_users[0]->{id} != $userid ) ) ) {
        return { success => 0, msg => '不能修改别人'  };
    }
    eval {
        $db->{dbh}->begin_work;
        foreach ( @delete_users ) {
            $db->exec('DELETE FROM SERIES_USERS WHERE userid=? AND siries_id=? AND stage=?', [$_, $siries_id, $stage], 0, 0); # delete from current stage only
        }
        my $basePoint = getBasePoint($siries_id, 'users');
        foreach ( @add_users ) {
            $db->exec( "INSERT OR IGNORE INTO SERIES_USERS(siries_id, stage, group_number, userid, original_point) VALUES(?,?,?,?,?);",
                [$siries_id, $stage, $_->{group}, $_->{id}, $basePoint->{$_->{id}} // DEFAULT_POINT ], 0, 0 );
        }
        foreach ( @changed_users ) {
            $db->exec( "UPDATE SERIES_USERS SET group_number=? WHERE siries_id=? AND stage=? AND userid=?;",
                [$_->{group}, $siries_id, $stage, $_->{id}], 0, 0 );
        }
        $db->{dbh}->commit();
    };
    if ( $@ ) {
        $db->{dbh}->rollback();
        return { success => 0, msg => $db->{errstr} };
    }
    { success => 1, msg=>"增加了" . scalar @add_users . "个人员，删除了" . scalar @delete_users . "个人员，修改了" . scalar @changed_users . "个人员" }
}

sub getUserList() {
    my $filter = $q->param('filter') // '';
    my $sql = 'SELECT name || ", " || cn_name || ", " || nick_name as full_name, * FROM USERS ' . ( $filter ? 'WHERE logintype<=?' : '' ) . ' ORDER BY userid ASC;';
    my @val = $db->exec($sql, $filter ? [1] : undef, 1);
    { success=>!$db->{error}, users=>\@val };
}

sub getRefPoint($points, $date) {
    foreach my $d ( sort { $b cmp $a } keys $points->%* ) {
        return $points->{$d} if $date gt $d;
    }
    return 0;
}

sub getSeriesDate($series) {
    return if $db->{error};
    my @dates = $db->exec('SELECT siries_id, stage, start, end FROM SERIES_DATE ORDER BY siries_id,stage DESC', undef, 1); # only stage DESC
    return if $db->{error};
    my (%d, %l);
    foreach (@dates) {
        $_->{start} ||= '';
        $d{$_->{siries_id}}->{$_->{stage}}->{start} = $_->{start};
        $d{$_->{siries_id}}->{$_->{stage}}->{end} = $_->{end};
        $l{$_->{siries_id}} = $_->{start}; # record next stage start time, and at the end it will record 1st stage start
    }
    foreach my $s ( $series->@* ) {
        my $d = $d{$s->{siries_id}} // {};
        $s->{start} = $l{$s->{siries_id}} // '';
        $s->{end} = $d->{&STAGE_END . ''}->{start} // ''; # for end, only 'start' is needed
        $s->{duration} = ( $s->{start} && $s->{end} ) ? (Time::Piece->strptime($s->{end}, '%Y-%m-%d') - Time::Piece->strptime($s->{start}, '%Y-%m-%d') + ONE_DAY)->days : '';
        foreach my $stage ( sort keys $stage_name->%* ) {
            next if !defined $d->{$stage}->{start} && !defined $d->{$stage}->{end};
            $s->{"start_$stage"} = $d->{$stage}->{start} // '';
            $s->{"end_$stage"} = $d->{$stage}->{end} // '';
        }
    }
}

sub replay() {
    # USERS: point need to be re-calc
    # SERIES: OK
    # SERIES_USERS: replay original_point
    # MATCHES: match_id reorder
    # MATCH_DETAILS: replay using GAMES
    # GAMES: OK
    # SERIES_DATE: OK
    $db->{dbh}->begin_work; # auto die when fail
    my @ids = $db->exec("SELECT match_details.match_id FROM match_details,matches WHERE matches.match_id=match_details.match_id AND win=1  ORDER BY date,match_details.match_id;", undef, 1);
    my $old_to_new;
    my $x = 1;
    foreach my $i ( @ids) {
        $old_to_new->{$i->{match_id}} = $x;   # 63 => 24
        $x++;
    }
    my @users = $db->exec("SELECT * FROM USERS;", undef, 1);
    my @series = $db->exec("SELECT * FROM SERIES ORDER BY siries_id;", undef, 1);
    my @series_users = $db->exec("SELECT * FROM SERIES_USERS;", undef, 1);
    my @matches = $db->exec("SELECT * FROM MATCHES ORDER BY match_id;", undef, 1);
    my @match_details = $db->exec("SELECT MATCH_DETAILS.* FROM MATCH_DETAILS,MATCHES WHERE MATCH_DETAILS.MATCH_ID=MATCHES.MATCH_ID ORDER BY date,match_id;", undef, 1);
    my @games = $db->exec("SELECT * FROM GAMES ORDER BY game_id;", undef, 1);
    my @series_date = $db->exec("SELECT * FROM SERIES_DATE;", undef, 1);
    getSeriesDate(\@series);
    $db->{dbh}->rollback();
    $db->disconnect();

    # get init point
    my %points = (); # { id1 => 1600, ... } # init point
    my %points_date = (); # { id1 => { 2020 => 1600, 2021 => 1700, ... }, ... }
    my %points_ref = (); # { id1 => {series1 => { stage1 => 1600, ... }, ... }, ... }
    my %points_latest = (); # { id1 => 1600, ... }
    my %series_hash =  map {; $_->{siries_id} => $_ } @series;
    foreach my $m(@match_details) {
        $points{$m->{userid}} //= $m->{point_ref};
    }
    foreach my $u(@users) {
        $points{$u->{userid}} //= $u->{point};
        $points_date{$u->{userid}}->{'1900-00-00'} = $points{$u->{userid}};
    }
    %points_latest = %points;

    # get ref point and calc point
    my %match_hash = map {; $_->{match_id} => $_ } @matches; # { 145 => { match_id => 145, siries_id => 1, ... }, ... }
    my %series_users_hash;
    foreach ( @series_users ) {
        $series_users_hash{$_->{siries_id}}->{$_->{stage}}->{$_->{group_number}}->{$_->{userid}} = $_->{original_point};
    }
    my @new_md = ();
    foreach my $d (@match_details) {
        next if $d->{win} == 0;
        my ($match_id, $userid1, $win, $game_win, $game_lose, $userid2, $waive) = @{$d}{qw(match_id userid win game_win game_lose userid2 waive)};
        my $siries_id = $match_hash{$match_id}->{siries_id};
        my $stage = $match_hash{$match_id}->{stage};
        my $group_number = $match_hash{$match_id}->{group_number};
        my $match_date = $match_hash{$match_id}->{date};
        my $siries_date = $series_hash{$siries_id}->{"start_$stage"};
        my ($ref1, $ref2);
        my ($p1, $p2) = ($points_latest{$userid1}, $points_latest{$userid2});
        $ref1 = getRefPoint($points_date{$userid1}, $siries_date);
        $ref2 = getRefPoint($points_date{$userid2}, $siries_date);
        if ( $siries_id != 1 ) {
            $points_ref{$userid1}->{$siries_id}->{$stage} //= $ref1;
            $points_ref{$userid2}->{$siries_id}->{$stage} //= $ref2;
            $ref1 = $points_ref{$userid1}->{$siries_id}->{$stage};
            $ref2 = $points_ref{$userid2}->{$siries_id}->{$stage};
        }
        my ($new1, $new2 ) = calcPoints(1, $p1, $p2, $ref1, $ref2);
        $points_latest{$userid1} = $points_date{$userid1}->{$match_date} = $new1;
        $points_latest{$userid2} = $points_date{$userid2}->{$match_date} = $new2;
        push @new_md, [$old_to_new->{$match_id}, $userid1, $ref1, $p1, $new1, $win, 1-$win, $game_win, $game_lose, $userid2, $waive];
        push @new_md, [$old_to_new->{$match_id}, $userid2, $ref2, $p2, $new2, 1-$win, $win, $game_lose, $game_win, $userid1, $waive];
        push @series_users, { siries_id=> $siries_id, stage => $stage, userid => $userid1, group_number => $group_number } if !exists $series_users_hash{$siries_id}->{$stage}->{$group_number}->{$userid1};
        push @series_users, { siries_id=> $siries_id, stage => $stage, userid => $userid2, group_number => $group_number } if !exists $series_users_hash{$siries_id}->{$stage}->{$group_number}->{$userid2};
    }
    my %new_match_hash = map {; $old_to_new->{$_->{match_id}} => $_ } @matches;
    my @new_matches = ();
    foreach my $id ( sort { $a <=> $b } keys %new_match_hash ) {
        push @new_matches, $new_match_hash{$id};
    }
    my @new_games = sort { $old_to_new->{$a->{match_id}} <=> $old_to_new->{$b->{match_id}} || $a->{game_id} <=> $b->{game_id} } @games;
    foreach my $s (@series_users) {
        $s->{original_point} = $points_ref{$s->{userid}}->{$s->{siries_id}}->{$s->{stage}} // $s->{original_point};
    }

    my $new_db = db->new("test");
    $new_db->{dbh}->begin_work;
    foreach my $u(@users) { # $u: {userid => ..., }
        $new_db->exec("INSERT INTO USERS(userid,name,email,employeeNumber,logintype,gender,nick_name,cn_name,point) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(userid) DO NOTHING;",
            [@{$u}{qw(userid name email employeeNumber logintype gender nick_name cn_name)}, $points_latest{$u->{userid}}], 0 );
    }
    foreach my $s (@series) {
        $new_db->exec("INSERT INTO SERIES(siries_id,siries_name,number_of_groups,group_outlets,top_n,links,stage) VALUES(?,?,?,?,?,?,?) ON CONFLICT(siries_id) DO NOTHING;",
            [@{$s}{qw(siries_id siries_name number_of_groups group_outlets top_n links stage)}], 0 );
    }
    foreach my $m (@new_matches) {
        $new_db->exec("INSERT INTO MATCHES(match_id,siries_id,stage,group_number,date,comment) VALUES(?,?,?,?,?,?) ON CONFLICT(match_id) DO NOTHING;",
            [$old_to_new->{$m->{match_id}}, @{$m}{qw(siries_id stage group_number date comment)}], 0 );
    }
    foreach my $g (@new_games) {
        $new_db->exec("INSERT INTO GAMES(match_id,game_number,userid,win,lose) VALUES(?,?,?,?,?);",
            [$old_to_new->{$g->{match_id}}, @{$g}{qw(game_number userid win lose)}], 0 );
    }
    foreach my $s (@series_users) {
        $new_db->exec("INSERT OR IGNORE INTO SERIES_USERS(siries_id,stage,userid,original_point,group_number) VALUES(?,?,?,?,?);",
            [@{$s}{qw(siries_id stage userid original_point group_number)}], 0 );
    }
    foreach my $d (@new_md) {
        $new_db->exec("INSERT OR IGNORE INTO MATCH_DETAILS(match_id,userid,point_ref,point_before,point_after,win,lose,game_win,game_lose,userid2,waive) VALUES(?,?,?,?,?,?,?,?,?,?,?);",
            $d, 0 );
    }
    foreach my $d (@series_date) {
        $new_db->exec("INSERT OR IGNORE INTO SERIES_DATE(siries_id,stage,start,end) VALUES(?,?,?,?);",
            [@{$d}{qw(siries_id stage start end)}], 0 );
    }
    $new_db->{dbh}->commit();
    foreach my $u(@users) {
       if ( $u->{point} != $points_latest{$u->{userid}} ) {
           print "Wrong: $u->{userid}, $u->{point} != $points_latest{$u->{userid}}\n";
       }
    }
}

sub printheader($q) {
    print $q->header( -charset=>'utf-8',
                      -expires=>'now',
                    );
    my $js_settings = "var title = '$settings::title';\nvar extjs_root = '$extjs';\nvar avatar_template = '$settings::avatar_template';\n" .
                      "var debug=$settings::debug;\nvar more='';\n";
    print $q->start_html(-title=>$settings::title,
                         -encoding=>'utf-8',
                         -author=>'Opera.Wang',
                         -head=>Link({-rel=>'SHORTCUT ICON',-type=>'image/x-icon',-href=>"$imgd/tt.png"}),
                         -style=>{-src => ["$extjs/resources/css/ext-all.css",
                                           "$bracket/jquery.bracket.min.css",
                                           "tt.css",
                                          ]
                                 },
                         -script=>[{-src=>"$jquery/jquery" . ( $settings::debug ? "" : ".min" ) . ".js"},
                                   {-src=>"$extjs/adapter/ext/ext-base.js"},
                                   {-src=>"$extjs/ext-all" . ( $settings::debug ? "-debug" : "" ) . ".js"},
                                   {-src=>"$sprintf/sprintf" . ( $settings::debug ? "" : ".min" ) . ".js"},
                                   {-src=>"$echarts/echarts" . ( $settings::debug ? "" : ".min" ) . ".js"},
                                   {-src=>$settings::debug ? 'https://cdn.jsdelivr.net/npm/jquery-bracket/src/jquery.bracket.js' : "$bracket/jquery.bracket.min.js"},
                                   {-code=>$js_settings},
                                   {-src=>'more.js'},
                                   {-src=>"DynaGrid.js"},
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
    $userid = lc($ENV{REMOTE_USER} // $ENV{USER} // 'unknown'); # web use REMTOE_USER, console test use USER
    $ENV{REQUEST_URI} //= 'unknown'; # for cmdline test
    $q = new CGI;
    check_server($q);
    $db = db->new();
    my $action = $q->param('action') || '';
    my @valid_actions = qw(getGeneralInfo getUserList getUserInfo editUser getPointList isAdmin getMatch getMatches editMatch getSeries editSeries
        editSeriesUser getSeriesMatch getSeriesMatchGroups getPointHistory replay checkAllUsers);
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
        print $q->end_html();
    }
    $db->disconnect();
    exit 0;
}

main();

