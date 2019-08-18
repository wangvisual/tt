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
};

use settings;
use db;

my $imgd = 'etc';
my $extjs = 'https://cdnjs.cloudflare.com/ajax/libs/extjs/3.4.1-1';

my $userid = '';
# we already use utf8, perl will use unicode internally, so JSON shouldn't care about it
# https://stackoverflow.com/questions/10708297/perl-convert-a-string-to-utf-8-for-json-decode
# JSON->new->utf8(1)->decode, input must be UTF-8
# JSON->new->utf8(0)->decode, input must be Unicode chars
my $json = JSON::XS->new->utf8(0)->space_after->relaxed->allow_nonref;
my ($q,$db);
my $perPage = 40;

# https://perldoc.perl.org/Encode/MIME/Header.html
# http://hansekbrand.se/code/UTF8-emails.html
sub send_html_email($to, $subject, $msg) {
    my %mail = (
        From             => encode("MIME-Header", $settings::title) . ' <' . ($ENV{SERVER_ADMIN} // 'unknown') . '>',
        To               => $to,
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
    my $fail = { success=>0, users => [] };
    my @users = $db->exec('SELECT userid,name,nick_name,employeeNumber,cn_name,gender,point FROM USERS WHERE logintype<=? AND point>? ORDER BY userid ASC;', [1,0], 1);
    return $fail if $db->{err};
    my @win = $db->exec('SELECT sum(win) AS win, sum(lose) AS lose, userid FROM MATCHE_DETAILS GROUP BY userid;', undef, 1);
    return $fail if $db->{err};
    my $user = {}; # { weiw => { win => 0, fail => 1 } }
    foreach (@win) {
        $user->{$_->{userid}}->{win} = $_->{win};
        $user->{$_->{userid}}->{lose} = $_->{lose};
    }
    foreach (@users) {
        $_->{win} = $user->{$_->{userid}}->{win} // 0;
        $_->{lose} = $user->{$_->{userid}}->{lose} // 0;
    }
    { success=>1, users=>\@users };
}

# http://www.ctta.cn/xhgg/zcfg/2017/0621/149168.html
# 中国乒乓球协会竞赛积分管理办法(试行)
sub calcPoints($pure_win, $point1, $point2) {
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
    my $higher_point_win = ($point1 - $point2) * $pure_win > 0 ? 1 : 0;
    my $diff = abs($point1 - $point2);
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

sub saveMatch() {
    my $match_id = get_param('match_id') || -1;
    return { success => 0, msg => '非管理员不能修改比赛结果'  } if $match_id > 0 && !isAdmin();
    return { success => 0, msg => '管理员也不能修改比赛结果'  } if $match_id > 0;
    my $set_id = get_param('set_id') || -1;
    my $date = get_param('date', ''); # 2019-08-17
    my $userid1 = get_param('userid1', '');
    my $userid2 = get_param('userid2', '');
    return { success => 0, msg => '输入信息不正确' } if $set_id < 0 || !$date || !$userid1 || !$userid2 || $userid1 eq $userid2;
    my @sets = $db->exec('SELECT set_id, set_name, stage FROM SETS where set_id=? and stage<=?;', [$set_id, 1], 1);
    return { success => 0, msg => '找不到合适的比赛项目' } if $db->{err} || scalar @sets != 1;
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
    my ($point1, $point2) = ( DEFAULT_POINT, DEFAULT_POINT );
    foreach (@points) {
        $point1 = $_->{point} if $_->{userid} eq $userid1;
        $point2 = $_->{point} if $_->{userid} eq $userid2;
        push @to, $_->{email} if $_->{email} =~ /\@/;
        $names{$_->{userid}} = $_->{full_name};
    }
    my ($new_point1, $new_point2) = calcPoints($win1-$win2, $point1, $point2);
    my ($diff1, $diff2) = ($new_point1 - $point1, $new_point2 - $point2);
    my $win = $win1 - $win2 > 0 ? 1 : 0;
    my $lose = 1 - $win;

    # update DB using transcation
    {
        $db->{dbh}->begin_work;
        $db->exec("INSERT INTO MATCHES(set_id, date, comment) VALUES(?,?,?);", [$set_id, $date, $comment], 2, 0);
        $match_id = $db->{last_insert_id};
        last if $db->{err} || $match_id <= 0;
        $db->exec("INSERT INTO MATCHE_DETAILS(match_id, userid, point_before, point_after, win, lose, game_win, game_lose, userid2) VALUES(?,?,?,?,?,?,?,?,?);",
                  [$match_id, $userid1, $point1, $new_point1, $win, $lose, $win1, $win2, $userid2], 0, 0);
        last if $db->{err};
        $db->exec("INSERT INTO MATCHE_DETAILS(match_id, userid, point_before, point_after, win, lose, game_win, game_lose, userid2) VALUES(?,?,?,?,?,?,?,?,?);",
                  [$match_id, $userid2, $point2, $new_point2, $lose, $win, $win2, $win1, $userid1], 0, 0);
        last if $db->{err};
        foreach (my $number = 0;  $number < scalar @games; $number++ ) {
            $db->exec("INSERT INTO GAMES(match_id, game_number, userid, win, lose) VALUES(?,?,?,?,?);",
                      [$match_id, $number, $userid1, $games[$number]->[0], $games[$number]->[1]], 0, 0);
            last if $db->{err};
            $db->exec("INSERT INTO GAMES(match_id, game_number, userid, win, lose) VALUES(?,?,?,?,?);",
                      [$match_id, $number, $userid2, $games[$number]->[1], $games[$number]->[0]], 0, 0);
            last if $db->{err};
        }
        last if $db->{err};
        $db->exec('UPDATE USERS set point=? where userid=?;', [$new_point1, $userid1], 0, 0);
        last if $db->{err};
        $db->exec('UPDATE USERS set point=? where userid=?;', [$new_point2, $userid2], 0, 0);
        last if $db->{err};
        $db->{dbh}->commit();
    }
    if ( $db->{err} ) {
        $db->{dbh}->rollback();
        return { success => 0, msg => "DB fail: $db->{errstr}" };
    }

    if ( $settings::mail ) {
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
    <h1>$sets[0]->{set_name} 比赛结果 @ $date</h1>
    <p>
        <table>
            <tr><th>参赛人员</th><th>比分</th><th>原积分</th><th>新积分</th><th>积分变动</th></tr>
            <tr><td>$names{$userid1}</td><td>$win1</td><td>$point1</td><td>$new_point1</td><td>$diff1</td></tr>
            <tr><td>$names{$userid2}</td><td>$win2</td><td>$point2</td><td>$new_point2</td><td>$diff2</td></tr>
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
    <p>
    请访问<a href='$https://$settings::servername$ENV{REQUEST_URI}'>$settings::title</a>获得详细信息
    </p>
    </body>
EOT
        send_html_email(join(', ', @to), '新比赛结果出来了', $content);
    }

    { success => 1, msg => "$userid1: $point1 => $new_point1, $userid2: $point2 => $new_point2" };
}

sub getMatchInfo() {
    my $match_id = get_param('match_id') || -1;
    #return { success=>1, match=>[] } if $match_id < 0;
    my @match = $db->exec('SELECT m.match_id, m.set_id, m.date, m.comment FROM MATCHES AS m, MATCHE_DETAILS AS d WHERE m.match_id=d.match_id AND m.match_id=? AND d.win=?;', [$match_id, 1], 1);
    my @games = $db->exec('SELECT g.game_id, g.game_number, g.userid, g.win, g.lose FROM GAMES AS g, MATCHES AS m WHERE m.match_id=g.match_id AND m.match_id=?;', [$match_id], 1);
    #$match[0]->{comment} = 'test';
    $match[0]->{set_id} = 1;
    $match[0]->{game1_point1} = 11;
    $match[0]->{game1_point2} = 7;
    $match[0]->{date} = '2019-08-13';
    { success=>1, match=>\@match };
}

sub getSets() {
    # TODO, 'filter'
    my @sets = $db->exec('SELECT set_id, set_name, number_of_groups, group_outlets, top_n, stage FROM SETS;', undef, 1);
    { success=>!$db->{errstr}, sets=>\@sets };
}

sub getUserList() {
    # TODO, filter
    my @val = $db->exec('SELECT name || ", " || cn_name || ", " || nick_name as full_name, * FROM USERS WHERE logintype<=? ORDER BY userid ASC;', [1], 1);
    { success=>!$db->{errstr}, users=>\@val };
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
                                   {-src=>"$extjs/ext-all.js"},
                                   #{-src=>"$extjs/ext-all-debug.js"},
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
    my @valid_actions = qw(getGeneralInfo getUserList getUserInfo editUser getPointList isAdmin getMatchInfo saveMatch getSets);
    if ( $action ) {
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

