package ProxmodTest;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK =
    qw(tempdir write_file capture_log capture_debug_log is_tainted repo_root perl_bin);

use File::Temp ();
use File::Path ();
use File::Basename ();

# Shared helpers for the unit tests. None of these need a Proxmox host: the
# whole point of t/ is that proxmod's logic can be checked on a laptop, leaving
# test/qemu/ to prove only the things that genuinely require a live PVE.

# Several tests carry a -T shebang so they can assert on taint behaviour, and
# under -T perl refuses to run any external command while $ENV{PATH} is tainted
# — which it always is, since it came from the shell. Merely using this module
# makes the environment safe enough to spawn a subprocess.
BEGIN {
    $ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';
    delete @ENV{qw(IFS CDPATH ENV BASH_ENV PERL5LIB PERL5OPT PROXMOD_DEBUG)};
}

# Kept alive for the process lifetime; File::Temp removes them at exit.
my @keep;

sub tempdir {
    my $dir = File::Temp->newdir(TEMPLATE => 'proxmod-t-XXXXXX', TMPDIR => 1);
    push @keep, $dir;

    # The path derives from $ENV{TMPDIR} and so is tainted. Tests pass it to
    # subprocesses, which -T forbids for tainted data, so untaint it here — and
    # fail loudly rather than quietly if it looks unusual.
    my ($clean) = ("$dir" =~ m{\A([\w./+-]+)\z});
    die "refusing to use a temporary directory with odd characters: $dir"
        if !defined $clean;

    return $clean;
}

sub write_file {
    my ($path, $content) = @_;
    File::Path::make_path(File::Basename::dirname($path));
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    print {$fh} $content;
    close($fh) or die "cannot close $path: $!";
    return $path;
}

# Run $code with Proxmod::Log redirected into a string. Returns ($result,
# $log_text). Tests assert on the log because, for proxmod, the log *is* the
# user-visible behaviour: when an extension fails the daemon carries on
# regardless, so the journal line is the only thing an administrator gets.
sub capture_log {
    my ($code) = @_;

    require Proxmod::Log;

    my $buf = '';
    open(my $fh, '>', \$buf) or die "cannot open in-memory handle: $!";

    my $result;
    {
        local $Proxmod::Log::FH = $fh;
        # Hermetic: never let a real /etc/proxmod/proxmod.conf on the machine
        # running the tests decide whether debug output appears.
        local $Proxmod::Log::CONF_FILE = '/nonexistent/proxmod-test.conf';
        Proxmod::Log::_reset_cache();
        $result = $code->();
    }

    close($fh);
    Proxmod::Log::_reset_cache();

    return ($result, $buf);
}

# The standard taint probe: interpolating a tainted value into eval STRING is an
# insecure dependency, so eval sets $@. Only meaningful under -T; returns false
# everywhere else, which is why the tests that use it carry a -T shebang.
# Same, with debug output turned on.
#
# Several of proxmod's decisions are only visible as a debug line: an already
# mounted extension, a route that checked out, a duplicate registration that was
# absorbed. Those are exactly the paths where the code does nothing, so the log
# line is the only evidence a test can assert on. PROXMOD_DEBUG is set for the
# dynamic extent of the call, and Proxmod::Log rereads it because capture_log
# clears its cache.
sub capture_debug_log {
    my ($code) = @_;
    local $ENV{PROXMOD_DEBUG} = 1;
    return capture_log($code);
}

sub is_tainted {
    my ($value) = @_;
    return 0 if !defined $value;
    local $@;
    eval { eval '#' . substr($value, 0, 0); 1 };
    return length($@) ? 1 : 0;
}

sub repo_root {
    my $root = File::Basename::dirname(File::Basename::dirname(__FILE__));
    $root = File::Basename::dirname($root) if File::Basename::basename($root) eq 't';
    return $root;
}

# Untainted path to the running perl, for tests that need a subprocess.
sub perl_bin {
    my ($clean) = ($^X =~ m{\A([\w./+-]+)\z});
    die "refusing to exec a suspicious \$^X: $^X" if !defined $clean;
    return $clean;
}

1;
