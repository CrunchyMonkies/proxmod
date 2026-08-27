package Proxmod::Backend;

use strict;
use warnings;

use Proxmod::Log qw(log_debug log_info log_warn log_error);
use Proxmod::API;

our $VERSION = '0.2.2';

# Loads each extension's Perl module and lets it register its endpoints.
#
# Called from Proxmod::Boot once per daemon start, with the extensions that
# declared this daemon. Boot already runs this whole stage inside an eval; the
# second layer of containment here is per extension, and it is the one that
# matters — the entire point is that one extension whose module does not compile
# costs exactly itself and nothing else.

# The sub an extension's module must define. It is called with a Proxmod::API
# object scoped to that extension:
#
#     sub proxmod_register {
#         my ($api) = @_;
#         $api->mount(scope => 'node', subclass => __PACKAGE__);
#         $api->add_method(class => __PACKAGE__, name => 'index', ...);
#     }
our $ENTRY_POINT = 'proxmod_register';

sub install {
    my ($daemon, $exts) = @_;

    my ($loaded, $failed) = (0, 0);

    for my $ext (@{ $exts || [] }) {
        my $id = defined $ext->{id} ? $ext->{id} : '<unnamed>';

        my $ok = eval {
            local $SIG{__DIE__} = 'DEFAULT';
            _install_one($daemon, $ext);
            1;
        };

        if ($ok) {
            $loaded++;
            next;
        }

        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        $err =~ s/\s*\n\s*/ /g;
        log_error("extension $id: not loaded: $err");
        $failed++;
    }

    return { loaded => $loaded, failed => $failed };
}

sub _install_one {
    my ($daemon, $ext) = @_;

    my $id = $ext->{id};
    die "the registry produced an extension with no id\n"
        if !defined $id || $id eq '';

    my $module = $ext->{backend} && $ext->{backend}{module};
    die "no backend module declared\n" if !defined $module || $module eq '';

    _load_module($module);

    my $entry = $module->can($ENTRY_POINT);
    die "$module does not define $ENTRY_POINT()\n" if !$entry;

    my $api = Proxmod::API->new(
        id => $id,
        version => $ext->{version},
        daemon => $daemon,
    );

    $entry->($api);

    log_debug("extension $id: $module registered");

    return;
}

# The module name comes from a manifest read off disk, so under -T it is
# tainted, and `require` of a tainted string dies [PVE-F-042]. Proxmod::Registry
# has already rebuilt it from a strict package-name capture; this second check
# is here because the cost of being wrong is arbitrary code execution as root
# inside pvedaemon, and it costs one regex.
#
# Note the deliberate absence of `eval "require $module"`. Converting the name
# to a relative path and requiring that keeps a string that came from disk out
# of the compiler entirely.
sub _load_module {
    my ($module) = @_;

    my ($clean) = ($module =~ /\A([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)\z/);
    die "'$module' is not a valid module name\n" if !defined $clean;

    my $file = $clean;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    require $file;

    return;
}

1;
