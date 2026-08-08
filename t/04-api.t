#!/usr/bin/perl -T

use strict;
use warnings;

use lib 't/lib';
use lib 'perl';

use Test::More tests => 18;
use ProxmodTest qw(capture_log capture_debug_log is_tainted);

use PVE::API2;
use Proxmod::API;

# Proxmod::API is the surface every backend extension codes against, and almost
# everything it does is a check performed BEFORE Proxmox's own registration —
# because Proxmox's registration dies, at INIT time, inside pvedaemon.
#
# The PVE::RESTHandler under t/lib is not a friendly stand-in: register_method,
# map_path_to_methods and find_handler are copied from pve-manager 9.1.1. Every
# "dies" and every "does not resolve" below is Proxmox's real behaviour, which
# is the only reason asserting on it is worth anything.

# Handler classes for the tests. Bare @ISA rather than `use base` so they can be
# declared after PVE::RESTHandler is already loaded, without a BEGIN dance.
{
    no strict 'refs'; ## no critic (ProhibitNoStrict)
    for my $c (qw(T::Hello T::Other T::Nested T::Greedy)) {
        @{"${c}::ISA"} = ('PVE::RESTHandler');
    }
}

# Registration in PVE::RESTHandler is process-global, and so is Proxmod::API's
# view of what has been mounted. Every group below starts from nothing.
sub reset_all {
    PVE::API2::_build_tree();
    Proxmod::API::_reset();
    return;
}

# A method info hash with everything add_method insists on, so a test can vary
# exactly one field and attribute the failure to it.
sub method_args {
    my (%override) = @_;
    return (
        class => 'T::Hello',
        name => 'index',
        path => '',
        method => 'GET',
        permissions => { user => 'all' },
        description => 'test',
        parameters => { additionalProperties => 0, properties => {} },
        returns => { type => 'null' },
        code => sub { return },
        %override,
    );
}

sub api_for { return Proxmod::API->new(id => $_[0], daemon => 'pvedaemon') }

# What would a real request to this path reach?
sub resolves_to {
    my ($method, $path) = @_;
    my ($class, $info) = PVE::API2->find_handler($method, $path, {});
    return ($class, $info);
}

# ---------------------------------------------------------------------------
# Mounting
# ---------------------------------------------------------------------------

subtest 'mount claims exactly one path, under proxmod own segment' => sub {
    plan tests => 8;

    reset_all();
    my $api = api_for('hello');

    my ($path, $log) = capture_log(sub { $api->mount(scope => 'node', subclass => 'T::Hello') });

    is($path, '/nodes/{node}/proxmod/hello', 'the path is derived from the id, not chosen');
    like($log, qr{mounted T::Hello}, 'the mount is announced to the journal');

    # The root index has to answer before anything is mounted beneath it,
    # otherwise the extension's own subtree hangs off nothing.
    my ($root_class) = resolves_to('GET', '/nodes/n1/proxmod');
    is($root_class, 'Proxmod::API::Node', '/nodes/{node}/proxmod is served by the proxmod root');

    # And the segment is claimed from the class Proxmox actually mounts at
    # /nodes/{node}, not from somewhere convenient.
    my ($nodeinfo) = resolves_to('GET', '/nodes/n1');
    is($nodeinfo, 'PVE::API2::Nodes::Nodeinfo', 'the parent is the real PVE node class');

    # Proxmox's own endpoints are untouched by the mount.
    my ($qemu) = resolves_to('GET', '/nodes/n1/qemu');
    is($qemu, 'PVE::API2::Qemu', 'an existing PVE folder still resolves');

    my $reg = Proxmod::API::registrations();
    is(scalar(@$reg), 1, 'the registration is listed');
    is($reg->[0]{id}, 'hello', '...under the extension id');
    is($reg->[0]{scope}, 'node', '...in the scope it asked for');
};

subtest 'the root index lists what is mounted' => sub {
    plan tests => 3;

    reset_all();
    capture_log(sub {
        api_for('bbb')->mount(subclass => 'T::Other');
        api_for('aaa')->mount(subclass => 'T::Hello');
    });

    my (undef, $info) = resolves_to('GET', '/nodes/n1/proxmod');
    my $index = $info->{code}->({ node => 'n1' });

    is(scalar(@$index), 2, 'both extensions appear');
    is($index->[0]{subdir}, 'aaa', 'sorted by id, not by load order');
    is($index->[1]{handler}, 'T::Other', 'each entry names its handler class');
};

subtest 'two extensions cannot collide' => sub {
    plan tests => 4;

    reset_all();
    capture_log(sub {
        api_for('one')->mount(subclass => 'T::Hello');
        api_for('two')->mount(subclass => 'T::Other');
    });

    my ($a) = resolves_to('GET', '/nodes/n1/proxmod/one');
    my ($b) = resolves_to('GET', '/nodes/n1/proxmod/two');

    # Both are SUBCLASS mounts with no methods registered yet, so nothing
    # resolves through them — but the tree walk still gets that far.
    is($a, undef, 'a mount with no methods yet answers nothing');
    is($b, undef, '...for both of them');

    # The collision that would matter is two extensions with the same id, and
    # the registry makes ids unique, so the only way to reach it is by trying.
    reset_all();
    capture_log(sub { api_for('same')->mount(subclass => 'T::Hello') });
    my $err = do {
        local $@;
        eval { capture_log(sub { api_for('same')->mount(subclass => 'T::Other') }) };
        $@;
    };
    like($err, qr{already served by T::Hello}, 'a second class at the same id is refused');

    # Not by dying inside PVE's registry, which is the failure mode being
    # avoided: that would happen at INIT and take pvedaemon with it.
    unlike($err, qr{duplicate method definition}, '...before PVE::RESTHandler gets the chance to die');
};

subtest 'mounting the same class twice is a no-op' => sub {
    plan tests => 2;

    reset_all();
    my $api = api_for('hello');

    my ($first) = capture_log(sub { $api->mount(subclass => 'T::Hello') });
    my ($second, $log) = capture_debug_log(sub { $api->mount(subclass => 'T::Hello') });

    is($second, $first, 'the same path comes back');
    like($log, qr{already mounted}, 'and it says so rather than pretending it did work');
};

subtest 'mount refuses what it cannot safely register' => sub {
    plan tests => 6;

    reset_all();
    my $api = api_for('hello');

    like(_dies(sub { $api->mount(subclass => undef) }),
        qr{subclass is required}, 'no subclass');

    like(_dies(sub { $api->mount(subclass => 'T::Hello; system("rm -rf /")') }),
        qr{not a valid package name}, 'a package name that is not one');

    like(_dies(sub { $api->mount(subclass => 'No::Such::Class') }),
        qr{is not loaded}, 'a class that is not loaded');

    like(_dies(sub { $api->mount(scope => 'nowhere', subclass => 'T::Hello') }),
        qr{unknown scope 'nowhere'}, 'a scope that does not exist');

    like(_dies(sub { $api->mount(scope => 'nowhere', subclass => 'T::Hello') }),
        qr{node, cluster|cluster, node}, '...and it says which scopes there are');

    # Nothing above should have left a partial mount behind.
    is(scalar(@{ Proxmod::API::registrations() }), 0, 'a refused mount registers nothing');
};

subtest 'cluster scope mounts under PVE::API2::Cluster' => sub {
    plan tests => 3;

    reset_all();
    my $api = api_for('hello');

    my ($path) = capture_log(sub { $api->mount(scope => 'cluster', subclass => 'T::Hello') });
    is($path, '/cluster/proxmod/hello', 'the cluster path has no node in it');

    my ($root) = resolves_to('GET', '/cluster/proxmod');
    is($root, 'Proxmod::API::Cluster', 'served by the cluster root class');

    my ($existing) = resolves_to('GET', '/cluster');
    is($existing, 'PVE::API2::Cluster', "PVE's own cluster index still resolves");
};

subtest 'one extension may take both scopes' => sub {
    plan tests => 2;

    reset_all();
    my $api = api_for('hello');

    my ($node) = capture_log(sub { $api->mount(scope => 'node', subclass => 'T::Hello') });
    my ($cluster) = capture_log(sub { $api->mount(scope => 'cluster', subclass => 'T::Other') });

    is($node, '/nodes/{node}/proxmod/hello', 'node scope');
    is($cluster, '/cluster/proxmod/hello', 'cluster scope, same id, different subtree');
};

subtest 'a scope whose parent is gone is refused, not guessed at' => sub {
    plan tests => 2;

    reset_all();

    local $Proxmod::API::SCOPES{gone} = {
        parent => 'PVE::API2::Departed',
        root => 'Proxmod::API::Gone',
        prefix => '/gone/proxmod',
        probe => '/gone/proxmod',
        params => {},
    };

    my $err = _dies(sub { api_for('hello')->mount(scope => 'gone', subclass => 'T::Hello') });
    like($err, qr{PVE::API2::Departed is not available}, 'names the class that vanished');
    like($err, qr{scope 'gone' cannot be used}, 'and what that costs');
};

subtest 'a mount that does not resolve is reported, not assumed' => sub {
    plan tests => 2;

    reset_all();

    # The parent exists and the mount succeeds, but the path proxmod believes it
    # serves is not the path it ended up at. This is what a Proxmox reshuffle
    # looks like from the inside.
    local $Proxmod::API::SCOPES{skew} = {
        parent => 'PVE::API2::Cluster',
        root => 'Proxmod::API::Skew',
        prefix => '/cluster/elsewhere',
        probe => '/cluster/elsewhere',
        params => {},
    };

    my (undef, $log) = capture_log(sub {
        api_for('hello')->mount(scope => 'skew', subclass => 'T::Hello');
    });

    like($log, qr{does not resolve}, 'the journal says the endpoints are unreachable');
    like($log, qr{error|warn}, 'at a level an administrator would notice');
};

# ---------------------------------------------------------------------------
# Methods
# ---------------------------------------------------------------------------

subtest 'add_method registers a reachable endpoint' => sub {
    plan tests => 5;

    reset_all();
    my $api = api_for('hello');
    capture_log(sub { $api->mount(subclass => 'T::Hello') });

    my ($full, $log) = capture_debug_log(sub {
        $api->add_method(method_args(name => 'greet', path => 'greet'));
    });

    is($full, '/nodes/proxmod-probe/proxmod/hello/greet', 'the probe path is returned');
    like($log, qr{is reachable}, 'the route was checked, and said so');
    unlike($log, qr{unreachable|shadowed}, 'no complaint');

    my ($class, $info) = resolves_to('GET', '/nodes/n1/proxmod/hello/greet');
    is($class, 'T::Hello', 'a real request reaches the extension class');
    is($info->{name}, 'greet', '...and the method it registered');
};

subtest 'a method at the subtree root resolves at the mount path' => sub {
    plan tests => 2;

    reset_all();
    my $api = api_for('hello');
    capture_log(sub {
        $api->mount(subclass => 'T::Hello');
        $api->add_method(method_args(name => 'index', path => ''));
    });

    my ($class, $info) = resolves_to('GET', '/nodes/n1/proxmod/hello');
    is($class, 'T::Hello', 'GET on the mount point itself resolves');
    is($info->{name}, 'index', '...to the index method');
};

subtest 'permissions must be a decision, never an omission' => sub {
    plan tests => 8;

    reset_all();
    my $api = api_for('hello');
    capture_log(sub { $api->mount(subclass => 'T::Hello') });

    my %base = method_args();
    delete $base{permissions};

    my $err = _dies(sub { $api->add_method(%base) });
    like($err, qr{must carry a 'permissions' key}, 'omitting permissions is refused');
    like($err, qr{permissions => undef}, '...and the message says how to ask for root-only');

    # PVE's own rule: no permissions block means root@pam and nothing else, with
    # nothing logged about it [PVE-F-050]. proxmod will not stop you asking for
    # that — only from asking for it by accident.
    my ($ok) = capture_log(sub {
        $api->add_method(method_args(name => 'rootonly', path => 'rootonly', permissions => undef));
    });
    ok($ok, 'permissions => undef is accepted as an explicit choice');
    my (undef, $info) = resolves_to('GET', '/nodes/n1/proxmod/hello/rootonly');
    ok(exists $info->{permissions} && !defined $info->{permissions},
        '...and reaches PVE as the undef it wants to see');

    like(_dies(sub { $api->add_method(method_args(name => 'x1', path => 'x1', permissions => [])) }),
        qr{must be a hash reference}, 'a permissions list is refused');

    like(_dies(sub { $api->add_method(method_args(name => 'x2', path => 'x2', permissions => {})) }),
        qr{needs a 'user' or a 'check'}, 'an empty permissions hash is refused');

    like(
        _dies(sub {
            $api->add_method(method_args(name => 'x3', path => 'x3',
                permissions => { user => 'admin' }));
        }),
        qr{is not one PVE understands}, 'a permissions user PVE has never heard of is refused');

    # 'world' is legal and means "no login required". It is almost never what an
    # extension wants, so it is allowed but never quiet.
    my (undef, $log) = capture_log(sub {
        $api->add_method(method_args(name => 'open', path => 'open',
            permissions => { user => 'world' }));
    });
    like($log, qr{without authenticating}, "permissions user 'world' is warned about");
};

subtest 'add_method refuses malformed registrations' => sub {
    plan tests => 6;

    reset_all();
    my $api = api_for('hello');
    capture_log(sub { $api->mount(subclass => 'T::Hello') });

    like(_dies(sub { $api->add_method(method_args(class => undef)) }),
        qr{a class is required}, 'no class');

    like(_dies(sub { $api->add_method(method_args(class => 'No::Such::Class')) }),
        qr{is not loaded}, 'a class that is not loaded');

    like(_dies(sub { $api->add_method(method_args(name => undef)) }),
        qr{a name is required}, 'no name');

    like(_dies(sub { $api->add_method(method_args(path => undef)) }),
        qr{a path is required}, 'no path');

    like(_dies(sub { $api->add_method(method_args(code => 'not a sub')) }),
        qr{code must be a CODE reference}, 'code that is not code');

    like(_dies(sub { $api->add_method(method_args(method => 'PATCH')) }),
        qr{PVE dispatches}, 'an HTTP method PVE does not route');
};

subtest 'registering the same method twice does not kill the daemon' => sub {
    plan tests => 3;

    reset_all();
    my $api = api_for('hello');
    capture_log(sub { $api->mount(subclass => 'T::Hello') });

    my ($first) = capture_log(sub { $api->add_method(method_args(name => 'a', path => 'a')) });

    # PVE::RESTHandler dies on this. It would die at INIT, inside pvedaemon,
    # which is the difference between a missing extension and no hypervisor.
    my $raw = _dies(sub { T::Hello->register_method({ %{ { method_args(name => 'a', path => 'a') } } }) });
    like($raw, qr{duplicate method definition}, 'PVE really does die on a duplicate');

    my ($second, $log) = capture_debug_log(sub {
        $api->add_method(method_args(name => 'a', path => 'a'));
    });
    is($second, $first, 'proxmod returns the first registration instead');
    like($log, qr{already registered}, '...and says why nothing happened');
};

subtest 'a level holds folders or a parameter, never both' => sub {
    plan tests => 2;

    reset_all();

    # PVE::API2::Storage::Content's first path level is the regex {volume}. A
    # sibling folder at the same level is not a routing subtlety — Proxmox
    # refuses it outright, at registration, by dying.
    #
    # This is why proxmod claims its segment from PVE::API2::Nodes::Nodeinfo,
    # whose children are folders, and never from PVE::API2::Nodes, whose only
    # child is {node}.
    my $err = _dies(sub {
        PVE::API2::Storage::Content->register_method(
            { subclass => 'T::Greedy', path => 'nested' });
    });
    like($err, qr{regex and fixed items}, 'a folder beside a {param} is refused by PVE');

    my $ok = _dies(sub {
        PVE::API2::Nodes::Nodeinfo->register_method(
            { subclass => 'T::Greedy', path => 'somewhere' });
    });
    is($ok, '', 'a folder beside other folders is fine');
};

subtest 'a shadowed endpoint is reported' => sub {
    plan tests => 5;

    reset_all();

    # PVE::API2::Storage::Content is mounted with fragmentDelimiter => '',
    # which joins every remaining path fragment into one before matching. A
    # method registered deeper in that subtree registers perfectly and is then
    # never dispatched to: the request is swallowed by {volume}, which matches
    # 'anything/buried' as happily as it matches 'anything'.
    #
    # No extension can get itself into this position through mount(), because
    # proxmod's own roots are not greedy. It is reachable by an extension that
    # nests subclasses of its own, so the check has to work — and it is the
    # exact shape of the bug that forced pve-token-copy into existence.
    my $api = api_for('greedy');
    $api->{probes}{'PVE::API2::Storage::Content'} = '/nodes/n1/storage/local/content';

    my (undef, $log) = capture_debug_log(sub {
        $api->add_method(method_args(
            class => 'PVE::API2::Storage::Content',
            name => 'buried',
            path => '{volume}/buried',
        ));
    });

    like($log, qr{shadowed}, 'the journal says the endpoint will not be reached');
    like($log, qr{buried}, '...and names the method that will not be reached');
    like($log, qr{'info'}, '...and the one that answers instead');

    # The class-level check alone would have called this healthy, which is why
    # the post-check compares the registered method info by identity.
    my ($class, $info) = resolves_to('GET', '/nodes/n1/storage/local/content/vol/buried');
    is($class, 'PVE::API2::Storage::Content', 'the right class does answer');
    is($info->{name}, 'info', '...with the wrong method');
};

subtest 'assert_route answers the question proxmod-verify asks' => sub {
    plan tests => 3;

    reset_all();
    my $api = api_for('hello');
    capture_log(sub {
        $api->mount(subclass => 'T::Hello');
        $api->add_method(method_args(name => 'greet', path => 'greet'));
    });

    my ($ok, $msg) = $api->assert_route('GET', '/nodes/n1/proxmod/hello/greet', 'T::Hello');
    ok($ok, 'a live route confirms');

    my ($miss, $msg2) = $api->assert_route('GET', '/nodes/n1/proxmod/hello/nope', 'T::Hello');
    ok(!$miss, 'a path with no handler does not');
    like($msg2, qr{does not resolve}, '...and says so in words');
};

# ---------------------------------------------------------------------------
# Taint
# ---------------------------------------------------------------------------

subtest 'names that came off disk are untainted before they are used' => sub {
    plan tests => 3;

    reset_all();

    # A manifest is read from the filesystem, so under -T every string in it is
    # tainted, and a tainted class name reaching a method call or require is
    # fatal [PVE-F-042]. Proxmod::Registry untaints; Proxmod::API untaints again
    # because the cost of being wrong here is root.
    my $tainted = "T::Hello" . substr($ENV{PATH} // '', 0, 0);

    SKIP: {
        skip 'not running under taint', 3 if !is_tainted($tainted);

        ok(is_tainted($tainted), 'the fixture really is tainted');

        my $api = api_for('hello');
        my ($path) = capture_log(sub { $api->mount(subclass => $tainted) });
        is($path, '/nodes/{node}/proxmod/hello', 'a tainted class name still mounts');
        ok(!is_tainted($api->{probes}{'T::Hello'}),
            'and what proxmod keeps is the untainted capture');
    }
};

sub _dies {
    my ($code) = @_;
    local $@;
    my $buf = '';
    eval {
        open(my $fh, '>', \$buf) or die "in-memory handle: $!";
        local $Proxmod::Log::FH = $fh;
        local $Proxmod::Log::CONF_FILE = '/nonexistent/proxmod-test.conf';
        $code->();
        1;
    };
    return $@ || '';
}
