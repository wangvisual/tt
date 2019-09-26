package settings;

use strict;
use warnings;
use utf8;

$settings::debug = 0;
$settings::mail = 1;

$settings::ldapserver = "ldap";
$settings::name = 'displayName';
$settings::email = 'mail';
$settings::employeeNumber = 'employeeNumber';
$settings::baseDN = 'ou=people'; # Change this to the real baseDN
$settings::avatar_template = ''; # change this to url of the avatar

$settings::servername = ""; # Change this to the web server host name
$settings::title = '乒乓球比赛与积分系统';

1;
