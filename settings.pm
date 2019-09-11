package settings;

use strict;
use warnings;
use utf8;

$settings::debug = 1;
$settings::mail = 'weiw@synopsys.com';

$settings::ldapserver = "ldap";
$settings::name = 'displayName';
$settings::email = 'mail';
$settings::employeeNumber = 'employeeNumber';
$settings::baseDN = 'ou=people,o=synopsys.com'; # Change this to the real baseDN

$settings::servername = "peweb"; # Change this to the web server host name
$settings::title = '乒乓球比赛与积分系统测试版';

1;
