#! /depot/perl-5.22.0/bin/perl

use strict;
use warnings;
use FindBin qw($RealBin);
use POSIX qw(strftime);

my $backup = strftime("%A", localtime);

chdir($RealBin);
$ENV{PATH} = "/bin:.";

my $cmd = "sqlite3 db/$ENV{USER}.db '.backup db/$backup.db'";
system($cmd);

