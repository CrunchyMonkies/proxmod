#!/usr/bin/perl -T

use strict;
use warnings;

use lib 't/lib';
use lib 'perl';

use Test::More tests => 9;
use ProxmodTest qw(tempdir write_file capture_log capture_debug_log repo_root);

use PVE::RESTHandler;
use PVE::API2;
use PVE::JSONSchema;

use Proxmod::API;
use Proxmod::Backend;

# Backend turns registry entries into live endpoints. It has exactly one
# behaviour worth protecting, and this file is mostly about that one behaviour:
# an extension that blows up costs itself and nothing else. Everything below is
# a different way of blowing up.

# Extension modules are written into a temporary directory and reached through
# @INC, the same way they are reached on a host from /usr/share/perl5. Loading
# is `require`, so a module can only be loaded once per process — every module
# name here is therefore unique, and none is reused across subtests.
my $LIB = tempdir();
unshift @INC, $LIB;

# The name is only ever used to build a path, so let it be the whole check.
sub write_module {
    my ($package, $body) = @_;

    my $file = $package;
    $file =~ s{::}{/}g;

    write_file("$LIB/$file.pm", <<"PM");
package $package;
use strict;
use warnings;
our \@ISA = ('PVE::RESTHandler');
$body
1;
PM

    return $package;
}

# A module whose proxmod_register mounts itself and adds one method. This is the
# shape every well-behaved extension has.
sub good_body {
    my ($name) = @_;
    return <<"PM";
sub proxmod_register {
    my (\$api) = \@_;
    \$api->mount(scope => 'node', subclass => __PACKAGE__);
    \$api->add_method(
        class => __PACKAGE__,
        name => 'index',
        path => '',
        method => 'GET',
        permissions => { user => 'all' },
        description => '$name',
        parameters => { additionalProperties => 0, properties => {} },
        returns => { type => 'null' },
        code => sub { return },
    );
    return;
}
PM
}

sub ext {
    my (%override) = @_;
    return {
        id => 'e',
        version => '1.0',
        backend => { module => 'T::Missing', daemons => ['pvedaemon'] },
        %override,
    };
}

sub reset_all {
    PVE::API2::_build_tree();
    Proxmod::API::_reset();
    return;
}

# ---------------------------------------------------------------------------

subtest 'nothing to install is not a failure' => sub {
    plan tests => 4;

    reset_all();

    for my $exts (undef, []) {
        my ($result) = capture_log(sub { Proxmod::Backend::install('pvedaemon', $exts) });
        is($result->{loaded}, 0, 'nothing loaded');
        is($result->{failed}, 0, 'nothing failed');
    }
};

subtest 'a well-formed extension registers its endpoints' => sub {
    plan tests => 5;

    reset_all();

    my $mod = write_module('T::Good', good_body('good'));
    my ($result, $log) = capture_debug_log(sub {
        Proxmod::Backend::install('pvedaemon', [ext(id => 'good', backend => { module => $mod })]);
    });

    is($result->{loaded}, 1, 'counted as loaded');
    is($result->{failed}, 0, 'nothing failed');
    like($log, qr{\Qgood: T::Good registered\E}, 'the journal records the registration');

    my ($class) = PVE::API2->find_handler('GET', '/nodes/n1/proxmod/good', {});
    is($class, $mod, 'a request to its path reaches it');

    is_deeply(
        [map { $_->{id} } @{ Proxmod::API::registrations() }],
        ['good'],
        'and it claimed exactly one path',
    );
};

subtest 'a module that dies at require costs only itself' => sub {
    plan tests => 6;

    reset_all();

    # This is the whole reason Backend exists in the shape it does. On a host
    # the two extensions below are two unrelated Debian packages, and the
    # broken one must not be able to take the working one down with it — nor,
    # far more importantly, the hypervisor.
    my $bad = write_module('T::Explodes', 'die "deliberate compile-time failure\n";');
    my $good = write_module('T::Survivor', good_body('survivor'));

    my ($result, $log) = capture_log(sub {
        Proxmod::Backend::install('pvedaemon', [
            ext(id => 'boom', backend => { module => $bad }),
            ext(id => 'fine', backend => { module => $good }),
        ]);
    });

    is($result->{loaded}, 1, 'the working extension loaded');
    is($result->{failed}, 1, 'the broken one is counted as failed');
    like($log, qr{extension boom: not loaded}, 'the journal names the extension that failed');
    like($log, qr{deliberate compile-time failure}, '...and says what went wrong');
    unlike($log, qr{extension fine: not loaded}, '...and does not blame the other one');

    my ($class) = PVE::API2->find_handler('GET', '/nodes/n1/proxmod/fine', {});
    is($class, $good, 'the working extension is live regardless');
};

subtest 'a multi-line failure becomes one journal line' => sub {
    plan tests => 2;

    reset_all();

    # Perl's die messages routinely carry a stack of "...propagated at" lines.
    # journalctl output is read by people at 3am; one failure is one line.
    my $mod = write_module('T::Multiline', 'die "first line\nsecond line\nthird line\n";');

    my (undef, $log) = capture_log(sub {
        Proxmod::Backend::install('pvedaemon', [ext(id => 'multi', backend => { module => $mod })]);
    });

    my @lines = grep { length } split(/\n/, $log);
    is(scalar(@lines), 1, 'exactly one line was logged');
    like($lines[0], qr{first line second line third line}, 'with the whole message on it');
};

subtest 'a module without the entry point is a failure, not a crash' => sub {
    plan tests => 3;

    reset_all();

    my $mod = write_module('T::NoEntry', 'sub something_else { return }');

    my ($result, $log) = capture_log(sub {
        Proxmod::Backend::install('pvedaemon', [ext(id => 'noentry', backend => { module => $mod })]);
    });

    is($result->{failed}, 1, 'counted as failed');
    like($log, qr{\QT::NoEntry does not define proxmod_register\E},
        'the journal says exactly what is missing');
    like($log, qr{extension noentry}, '...and which extension to fix');
};

subtest 'an extension that dies inside proxmod_register is contained' => sub {
    plan tests => 4;

    reset_all();

    # The interesting case is a partial registration: this one mounts
    # successfully and then dies. The mount stands, because unwinding a
    # PVE::RESTHandler registration is not possible — so the contract is that
    # the extension is broken, not that the daemon is.
    my $mod = write_module('T::HalfWay', <<'PM');
sub proxmod_register {
    my ($api) = @_;
    $api->mount(scope => 'node', subclass => __PACKAGE__);
    die "changed my mind\n";
}
PM
    my $good = write_module('T::AfterHalfWay', good_body('after'));

    my ($result, $log) = capture_log(sub {
        Proxmod::Backend::install('pvedaemon', [
            ext(id => 'half', backend => { module => $mod }),
            ext(id => 'after', backend => { module => $good }),
        ]);
    });

    is($result->{loaded}, 1, 'only the healthy one is counted as loaded');
    is($result->{failed}, 1, 'the half-registered one is counted as failed');
    like($log, qr{changed my mind}, 'the journal carries the reason');

    my ($class) = PVE::API2->find_handler('GET', '/nodes/n1/proxmod/after', {});
    is($class, $good, 'the extension registered afterwards is unaffected');
};

subtest 'malformed registry entries are rejected before anything is loaded' => sub {
    plan tests => 8;

    reset_all();

    my @cases = (
        [ext(id => undef), qr{no id}, 'no id' ],
        [ext(id => ''), qr{no id}, 'empty id' ],
        [{ id => 'x' }, qr{no backend module}, 'no backend section' ],
        [ext(backend => {}), qr{no backend module}, 'no module key' ],
        [ext(backend => { module => '' }), qr{no backend module}, 'empty module name' ],
        # The dangerous ones. A manifest is a file on disk; a module name that
        # is really a path traversal or a shell fragment must never reach
        # require. Registry untaints these already — this is the second lock.
        [ext(backend => { module => '../../etc/passwd' }),
            qr{not a valid module name}, 'path traversal' ],
        [ext(backend => { module => 'T::Good; system("id")' }),
            qr{not a valid module name}, 'injection attempt' ],
        [ext(backend => { module => '5Bad' }), qr{not a valid module name}, 'bad identifier' ],
    );

    for my $case (@cases) {
        my ($entry, $want, $label) = @$case;
        my (undef, $log) = capture_log(sub {
            Proxmod::Backend::install('pvedaemon', [$entry]);
        });
        like($log, $want, "$label is refused");
    }
};

subtest 'the api object carries the extension identity' => sub {
    plan tests => 3;

    reset_all();

    # The API object is the only thing an extension is handed, and everything it
    # is allowed to do is derived from what is on it: the path it gets comes
    # from the id, and the log lines it produces are attributed by it.
    our $SEEN;
    my $mod = write_module('T::Introspect', 'sub proxmod_register { $main::SEEN = $_[0]; return }');
    capture_log(sub {
        Proxmod::Backend::install('pveproxy',
            [ext(id => 'ident', version => '2.5', backend => { module => $mod })]);
    });
    my $seen = $SEEN;

    is($seen->{id}, 'ident', 'the id from the manifest');
    is($seen->{version}, '2.5', 'the version from the manifest');
    is($seen->{daemon}, 'pveproxy', 'the daemon it is being loaded into');
};

subtest 'the shipped example loads end to end' => sub {
    plan tests => 5;

    reset_all();

    # examples/proxmod-example-hello is the executable form of the extension
    # contract, so it is worth rather more than an example: if this subtest
    # fails, the documented contract and the code have diverged.
    unshift @INC, repo_root() . '/examples/proxmod-example-hello/perl';

    my ($result, $log) = capture_log(sub {
        Proxmod::Backend::install('pvedaemon', [{
            id => 'example-hello',
            version => '0.1.0',
            backend => { module => 'ProxmodExample::Hello', daemons => ['pvedaemon', 'pveproxy'] },
        }]);
    });

    is($result->{loaded}, 1, 'it loads');
    unlike($log, qr{\b(?:warn|error)\b}, 'with nothing to complain about');

    for my $path (qw(/nodes/n1/proxmod/example-hello
        /nodes/n1/proxmod/example-hello/greet
        /nodes/n1/proxmod/example-hello/note)) {
        my $method = $path =~ m{/note\z} ? 'POST' : 'GET';
        my ($class) = PVE::API2->find_handler($method, $path, {});
        is($class, 'ProxmodExample::Hello', "$method $path reaches the example");
    }
};
