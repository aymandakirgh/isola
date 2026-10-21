# Loads Isola's MediaRemote helper into this (Apple-signed) perl and runs it.
use strict;
use warnings;
use DynaLoader;
my ($lib, $fn) = @ARGV;
my $handle = DynaLoader::dl_load_file($lib, 0) or die "cannot load $lib: " . DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($handle, $fn) or die "missing $fn";
DynaLoader::dl_install_xsub("main::run", $symbol);
run();
