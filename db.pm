package db;
use parent qw(Exporter);

use strict;
use warnings;
use feature qw(state signatures postderef switch);
no warnings qw(experimental::signatures experimental::postderef experimental::smartmatch);
use FindBin qw($RealBin);
use utf8;
use DBI;
use DBD::SQLite;
use Data::Dumper;

sub new($proto, $dbname = undef) {
    my $class = ref($proto) || $proto;
    my $self = {};
    bless($self, $class);

    $dbname //= $ENV{USER} // $ENV{SERVER_ADMIN} // 'unknown';
    $dbname =~ s/\@.*//;
    my $dbfile = "$RealBin/db/$dbname.db";
    my $dbfile_exists = -e $dbfile;
    my $option = {
        AutoCommit => 1,
        sqlite_unicode => 1, # for UTF8 strings
    };
    my $dbh = $self->{dbh} = DBI->connect("dbi:SQLite:dbname=$dbfile", "", "", $option) or die "connect DB $dbfile failed: $DBI::errstr";
    $dbh->{LongReadLen} = 1024000;
    $dbh->do("PRAGMA cache_size = -10000"); # default is 2000 for < 3.12, -2000 for >= 3.12, set to negtive number for KBytes, positive number for pages, -10000 is 10M Bytes
    $dbh->do("PRAGMA journal_mode = PERSIST");
    $dbh->do("PRAGMA temp_store = MEMORY");
    $dbh->do("PRAGMA synchronous = OFF"); # faster but not safe
    $dbh->do("PRAGMA locking_mode = NORMAL");
    $dbh->do("PRAGMA page_size = 4096");
    $self->init_db() if !$dbfile_exists;
    #$self->upgrade_db();

    return $self;
}

sub init_db($self) {
    my $dbh = $self->{dbh};
    # logintype: 0: admin, 1: normal 2: disabled
    $dbh->do("CREATE TABLE IF NOT EXISTS USERS (userid NOT NULL PRIMARY KEY, name NOT NULL, nick_name, cn_name, email NOT NULL, employeeNumber INTEGER NOT NULL, logintype INTEGER NOT NULL, gender NOT NULL DEFAULT '未知', point INTEGER NOT NULL DEFAULT 0)");
    $dbh->do("CREATE TABLE IF NOT EXISTS MATCHES (match_id INTEGER PRIMARY KEY ASC, siries_id INTEGER, stage INTEGER NOT NULL DEFAULT 1, group_number INTEGER DEFAULT 1, date TEXT not null, comment)");
    # 1, usera, 1600, 1600, 1605, 1, 0, 2, 1, userb
    # 1, userb, 1600, 1600, 1595, 0, 1, 1, 2, usera
    $dbh->do("CREATE TABLE IF NOT EXISTS MATCH_DETAILS (match_id INTEGER NOT NULL, userid NOT NULL, point_ref INTEGER NOT NULL, point_before INTEGER NOT NULL, point_after INTEGER NOT NULL, "
           . "win INTEGER NOT NULL, lose INTEGER NOT NULL, game_win INTEGER NOT NULL, game_lose INTEGER NOT NULL, userid2, PRIMARY KEY (match_id, userid))");
    # 1, 1, 1, usera, 11, 7
    # 2, 1, 1, userb, 7, 11
    # 3, 1, 2, usera, 9, 11
    # 4, 1, 2, usera, 11, 9
    # 5, 1, 3, userb, 11, 5
    # 6, 1, 3, userb, 5, 11
    $dbh->do("CREATE TABLE IF NOT EXISTS GAMES (game_id INTEGER PRIMARY KEY ASC, match_id INTEGER, game_number INTEGER NOT NULL, userid NOT NULL, win INTEGER NOT NULL, lose INTEGER NOT NULL)");
    # stage: 0 => enroll, 1 => 循环赛 ...
    $dbh->do("CREATE TABLE IF NOT EXISTS SERIES (siries_id INTEGER PRIMARY KEY ASC, siries_name NOT NULL, number_of_groups INTEGER NOT NULL DEFAULT 1,"
           . "group_outlets INTEGER NOT NULL DEFAULT 1, top_n INTEGER NOT NULL DEFAULT 1, stage INTEGER NOT NULL DEFAULT 0, links)");
    # When a siries changed from enroll to competition, or 循环赛=>淘汰赛, capture(update) the point snapshot into SERIES_USERS
    # If the siries never end(eg, 自由约战) or still in enroll stage, use point from USERS table as fallback when calc point
    # 报名: 1, 0, usera, 1600, null
    # 循环赛: 1, 1, usera, 1600, 1
    $dbh->do("CREATE TABLE IF NOT EXISTS SERIES_USERS(siries_id INTEGER NOT NULL, stage INTEGER NOT NULL, userid NOT NULL, original_point INTEGER, group_number INTEGER DEFAULT 1, PRIMARY KEY (siries_id, stage, userid))");
    $dbh->do("CREATE TABLE IF NOT EXISTS SERIES_DATE(siries_id INTEGER NOT NULL, stage INTEGER NOT NULL, start TEXT, PRIMARY KEY (siries_id, stage))");
    $self->exec("INSERT INTO SERIES(siries_id,siries_name,number_of_groups,group_outlets,top_n,stage) VALUES(?,?,?,?,?,?);", [1, '自由约战', 1, 1, 1, 3], 0 );
    $self->exec("INSERT INTO SERIES_DATE(siries_id, stage, start) VALUES(?,?,?);", [1, 3, '2019-08-01'], 0 );
    $dbh->do("PRAGMA user_version = 1");
}

sub upgrade_db($self) {
    my $dbh = $self->{dbh};
    my $user_version = $dbh->selectall_arrayref("PRAGMA user_version")->[0]->[0];
}

sub DESTROY {
    my $self = shift;
    $self->disconnect() if defined $self;
}

sub disconnect($self) {
    return if !$self->{dbh};
    #$self->{dbh}->do("PRAGMA optimize");
    $self->{dbh}->disconnect();
    delete $self->{dbh};
}

sub exec($self, $sql, $input, $needfetch, $transcation = 1) {
    $input = [] if !defined $input;
    warn "EXEC: $sql with input: " . join (', ',  $input->@* ) . "\n" if $settings::debug;
    my @val;
    my $sth;
    $self->{errstr} = '';
    $self->{err} = 0;
    eval {
        $transcation = 0 if !$self->{dbh}->{AutoCommit};
        $self->{dbh}->begin_work if $transcation; # set AutoCommit to 0
        $sth = $self->{dbh}->prepare( $sql );
        die $DBI::errstr if !defined $sth;
        for (my $i = 0; $i <= scalar $input->@*; $i++ ) {
            $sth->bind_param( $i+1, $input->[$i] );
        }
        $sth->execute();
        if ( $needfetch == 1 ) {
            while ( my $singlerow = $sth->fetchrow_hashref ) {
                push @val, $singlerow;
            }
        }
        $self->{dbh}->commit() if $transcation;
        $self->{last_insert_id} = $self->{dbh}->last_insert_id("","","","") if $needfetch == 2;
    };
    if ($@) {
        warn "Database error: $sql : $@\n" if $settings::debug;
        print STDERR "Database error: $sql : $@\n";
        $self->{errstr} = $DBI::errstr || '';
        $self->{err} = 1 if $self->{errstr} ne '';
        $self->{dbh}->rollback() if $transcation;
    }
    $sth->finish() if defined $sth;
    die "$self->{errstr}, $@\n" if $self->{err} && !$transcation; # eval should be used when transcation is controled by caller
    @val;
}

sub execsql($self, $sql, $needfetch) {
    $needfetch = 1 if ! defined $needfetch;
    return $self->exec($sql, undef, $needfetch);
}

1;
