use inc::Module::Install;
name 'AnyEvent-IMAPListen';
all_from 'lib/AnyEvent/IMAPListen.pm';

# requires '';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
use_test_base;
auto_include;
WriteAll;
