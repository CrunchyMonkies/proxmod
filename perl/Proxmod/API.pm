package Proxmod::API;

use strict;
use warnings;

use Proxmod::Log qw(log_debug log_info log_warn log_error);

our $VERSION = '0.4.0';

# The surface a backend extension codes against.
#
# Extensions do not call PVE::RESTHandler->register_method directly. They could
# — nothing stops them — but Proxmox's registration rules are unforgiving in
# ways that only show up as a dead daemon or a silently unreachable endpoint,
# and every one of those rules has a cheaper check available before the fact:
#
#   * register_method DIES on a duplicate path, and it dies at INIT time inside
#     pvedaemon. Two extensions choosing the same path, or one extension loaded
#     twice, would take the daemon down.
#   * A method with no `permissions` key is silently root@pam-only. That is not
#     an error, it is not logged, and it is the single most common way an
#     extension appears to work for its author and for nobody else.
#   * A level of the path tree holds EITHER named folders OR one {param} regex,
#     never both, and a subtree behind `fragmentDelimiter => ''` swallows every
#     remaining path fragment. Register in the wrong place and the route simply
#     never resolves.
#
# See docs/pve-facts.md [PVE-F-050] and [PVE-F-051] for the source these are
# read out of.
#
# THE NAMESPACE RULE. proxmod claims exactly one path segment from Proxmox —
# `proxmod` — under each scope it supports, and every extension lives beneath
# it, at its own extension id:
#
#     /nodes/{node}/proxmod/<id>/...
#     /cluster/proxmod/<id>/...
#
# That is what makes collisions between two extensions structurally impossible
# rather than a matter of good manners: ids are unique in the registry, so two
# extensions cannot be handed the same path. It also means a Proxmox upgrade
# that adds a new endpoint can only ever collide with the single name `proxmod`.

# Package name pattern. Every value that reaches `require` or a method call must
# survive this, because a module name can arrive from a manifest read off disk
# and is therefore tainted [PVE-F-042].
my $RE_PACKAGE = qr/\A([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)\z/;

our $SEGMENT = 'proxmod';

# `probe` is `prefix` with the {param} components replaced by literals, so it
# can be pushed through find_handler to ask what a real request would resolve
# to. The value is arbitrary; it only has to match the parameter's regex, which
# for a bare {node} is \S+.
our %SCOPES = (
    node => {
        parent => 'PVE::API2::Nodes::Nodeinfo',
        root => 'Proxmod::API::Node',
        prefix => "/nodes/{node}/$SEGMENT",
        probe => "/nodes/proxmod-probe/$SEGMENT",
        params => {
            node => { type => 'string', description => 'The cluster node name.' },
        },
    },
    cluster => {
        parent => 'PVE::API2::Cluster',
        root => 'Proxmod::API::Cluster',
        prefix => "/cluster/$SEGMENT",
        probe => "/cluster/$SEGMENT",
        params => {},
    },
);

# The API tree root, and the class every path walk starts from.
our $ROOT_CLASS = 'PVE::API2';

# scope => 1 once the root class exists and is mounted into PVE's tree.
my %root_ready;

# scope => { id => { subclass, path } }. Process-global on purpose: PVE's own
# registration is, and this is what lets one extension's mount be reported as a
# conflict with another's rather than as a mysterious die.
my %mounts;

# "class method path" => full path, for idempotent re-registration.
my %methods;

# Every route proxmod registered in this process, in registration order, as
# { id, class, method, path, route } — `route` being the full path a request
# would use. Only the classes proxmod mounted appear, because those are the
# only ones whose full path it can compute.
#
# add_method already resolves each of these as it registers it, and warns when
# one is unreachable. This ledger exists so the same question can be asked
# again later, from outside: that warning is emitted once, inside the daemon,
# at load time, and by the time an administrator wonders whether a
# pve-manager upgrade has shadowed an endpoint the line has scrolled out of the
# journal. proxmod-verify replays the ledger on demand.
my @routes;

sub routes { return [ @routes ] }

# Every seam wrapped in this process, in the order it was asked for, as
# { id, ext, kind, class, name, posture, wrapped, reason }. `wrapped` is 0 for a
# seam that was probed and not found, or skipped because this is the wrong
# daemon; `reason` says which.
#
# The ledger exists because "is this seam live right now" is a question with no
# other answer. A wrap that failed logs one line at load time, and by the time
# an administrator wonders whether a pve-manager upgrade moved a method, that
# line has scrolled out of the journal. proxmod-verify replays this the same way
# it replays @routes.
my @seams;

# "kind class name" => the record above, for idempotent re-wrapping.
my %seam_seen;

sub seams { return [ @seams ] }

sub _reset {
    %root_ready = ();
    %mounts = ();
    %methods = ();
    @routes = ();
    @seams = ();
    %seam_seen = ();
    return;
}

# Test-only. Forget the seams one owner installed, so a suite that restored the
# original subs by hand can install them again — without that, the idempotency
# above correctly refuses to re-wrap something it believes is already wrapped.
# Production never calls this: wraps go in once per daemon start and die with
# the process.
sub _forget_seams {
    my ($ext) = @_;

    @seams = grep { $_->{ext} ne $ext } @seams;

    for my $key (keys %seam_seen) {
        delete $seam_seen{$key} if $seam_seen{$key}->{ext} eq $ext;
    }

    return;
}

sub scopes { return sort keys %SCOPES }

# Everything registered so far, for the root index and for proxmod-verify.
sub registrations {
    my @out;
    for my $scope (sort keys %mounts) {
        for my $id (sort keys %{ $mounts{$scope} }) {
            push @out, { scope => $scope, id => $id, %{ $mounts{$scope}{$id} } };
        }
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# The proxmod root classes
# ---------------------------------------------------------------------------

# Created at runtime rather than as .pm files with `use base 'PVE::RESTHandler'`,
# because that would make Proxmod::API unloadable outside a PVE daemon — and
# proxmod-verify, the test suite and `perl -c` all load it there.
sub _ensure_root {
    my ($scope) = @_;

    my $spec = $SCOPES{$scope}
        or die "unknown scope '$scope' (known: " . join(', ', scopes()) . ")\n";

    return $spec->{root} if $root_ready{$scope};

    die "PVE::RESTHandler is not loaded; this is not a Proxmox daemon\n"
        if !PVE::RESTHandler->can('register_method');

    my $parent = $spec->{parent};
    die "$parent is not available in this process, so scope '$scope' cannot be used\n"
        if !$parent->can('register_method');

    my $root = $spec->{root};

    {
        no strict 'refs'; ## no critic (ProhibitNoStrict)
        push @{"${root}::ISA"}, 'PVE::RESTHandler'
            if !grep { $_ eq 'PVE::RESTHandler' } @{"${root}::ISA"};
    }

    # Registered before the mount, so that the moment the mount lands the path
    # already resolves to something.
    $root->register_method({
        name => 'index',
        path => '',
        method => 'GET',
        # Any authenticated user may ask which extensions exist. This lists
        # names and versions only; the extensions' own endpoints do their own
        # access control, which is where it belongs.
        permissions => { user => 'all' },
        description => 'Index of proxmod extensions registered at this level.',
        parameters => {
            additionalProperties => 0,
            properties => { %{ $spec->{params} } },
        },
        returns => {
            type => 'array',
            items => {
                type => 'object',
                properties => { subdir => { type => 'string' } },
            },
            links => [{ rel => 'child', href => '{subdir}' }],
        },
        code => sub {
            my $out = [];
            for my $id (sort keys %{ $mounts{$scope} || {} }) {
                push @$out, {
                    subdir => $id,
                    handler => $mounts{$scope}{$id}{subclass},
                };
            }
            return $out;
        },
    });

    $parent->register_method({ subclass => $root, path => $SEGMENT });

    $root_ready{$scope} = 1;

    # Did the mount actually land where we think it did? If Proxmox ever moves
    # this parent, or another framework has already claimed the name, this is
    # where it shows up — as a warning in the journal rather than as an endpoint
    # that quietly 404s.
    my ($resolved) = _resolve('GET', $spec->{probe});
    if (!defined $resolved) {
        log_warn("scope '$scope': mounted $root under $parent, but $spec->{probe}"
            . ' does not resolve; endpoints in this scope will not be reachable');
    } elsif ($resolved ne $root) {
        log_warn("scope '$scope': $spec->{probe} resolves to $resolved, not $root;"
            . ' something else has claimed this path');
    } else {
        log_debug("scope '$scope': $spec->{prefix} is served by $root");
    }

    return $root;
}

# What does a real request to this path land on? Returns the handler class and
# the method info hash PVE would dispatch to, or nothing.
#
# The info hash is the same reference that was handed to register_method, which
# makes it an exact identity check rather than a description that can match by
# accident. That distinction is load-bearing: inside a subtree with
# `fragmentDelimiter => ''` a deeper path resolves to the RIGHT class and the
# WRONG method [PVE-F-051], and comparing class names alone would call that
# healthy.
sub _resolve {
    my ($method, $path) = @_;

    my ($class, $info);
    local $@;
    eval {
        local $SIG{__DIE__} = 'DEFAULT';
        ($class, $info) = $ROOT_CLASS->find_handler($method, $path, {});
        1;
    };

    return ($class, $info);
}

# ---------------------------------------------------------------------------
# The extension-facing object
# ---------------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;

    my $id = $args{id};
    die "Proxmod::API->new: an extension id is required\n"
        if !defined $id || $id eq '';

    return bless {
        id => $id,
        version => $args{version},
        daemon => $args{daemon},
        # subclass => probe path, so add_method can check its own routes.
        probes => {},
    }, $class;
}

sub id { return $_[0]->{id} }
sub daemon { return $_[0]->{daemon} }

# Can this scope be mounted in this process at all?
#
# mount() dies when the scope's parent class is not loaded, which is right for a
# daemon — there, a missing PVE::API2::Cluster means something is badly wrong and
# the extension should fail loudly. It is not right in a command-line tool: `qm`
# and `pct` load the classes they need and no more, so PVE::API2::Cluster simply
# is not there, and an extension that mounts a cluster-scoped route would fail to
# register at all.
#
# That matters more than a missing route. An extension registers its endpoints
# and installs its seam wraps in the same proxmod_register call, so a mount that
# dies takes the wraps with it — and in a CLI the wraps are the entire reason for
# being there. Probing lets an extension put its routes where they mean something
# and its wraps everywhere.
#
# `pvesh` is the interesting case: it builds the full API tree, so the mount
# succeeds and proxmod's own endpoints become visible to it — which they have
# never been before.
sub scope_available {
    my ($self, $scope) = @_;

    my $spec = $SCOPES{$scope};

    return 0 if !$spec;
    return 0 if !PVE::RESTHandler->can('register_method');

    return $spec->{parent}->can('register_method') ? 1 : 0;
}

# Give this extension its own subtree of the API. Returns the path it was given.
# Idempotent: mounting the same class in the same scope twice is a no-op, and
# mounting a *different* class over it is an error rather than a silent win.
sub mount {
    my ($self, %args) = @_;

    my $id = $self->{id};
    my $scope = defined $args{scope} ? $args{scope} : 'node';

    my $spec = $SCOPES{$scope}
        or die "mount: unknown scope '$scope' (known: " . join(', ', scopes()) . ")\n";

    my $subclass = $args{subclass};
    die "mount: a subclass is required\n" if !defined $subclass || $subclass eq '';

    my ($clean) = ($subclass =~ $RE_PACKAGE);
    die "mount: '$subclass' is not a valid package name\n" if !defined $clean;
    $subclass = $clean; # untainted [PVE-F-042]

    die "mount: $subclass is not loaded, or is not a PVE::RESTHandler subclass\n"
        if !$subclass->can('register_method');

    if (my $prev = $mounts{$scope} && $mounts{$scope}{$id}) {
        die "mount: $spec->{prefix}/$id is already served by $prev->{subclass}\n"
            if $prev->{subclass} ne $subclass;
        log_debug("$id: already mounted at $prev->{path}");
        return $prev->{path};
    }

    my $root = _ensure_root($scope);

    # From here on PVE's registry is being mutated, so everything that can be
    # checked has been checked already.
    $root->register_method({ subclass => $subclass, path => $id });

    my $path = "$spec->{prefix}/$id";
    $mounts{$scope}{$id} = { subclass => $subclass, path => $path };
    $self->{probes}{$subclass} = "$spec->{probe}/$id";

    log_info("$id: mounted $subclass at $path");

    return $path;
}

# Register one endpoint. Takes PVE::RESTHandler->register_method's info hash,
# plus a `class` naming the handler class it belongs to.
sub add_method {
    my ($self, %args) = @_;

    my $id = $self->{id};

    my $class = delete $args{class};
    die "add_method: a class is required\n" if !defined $class || $class eq '';

    my ($clean) = ($class =~ $RE_PACKAGE);
    die "add_method: '$class' is not a valid package name\n" if !defined $clean;
    $class = $clean;

    die "add_method: $class is not loaded, or is not a PVE::RESTHandler subclass\n"
        if !$class->can('register_method');

    die "add_method: a name is required\n"
        if !defined $args{name} || $args{name} eq '';
    die "add_method: a path is required (use '' for the subtree root)\n"
        if !defined $args{path};
    die "add_method: code must be a CODE reference\n"
        if ref($args{code}) ne 'CODE';

    $args{method} = 'GET' if !defined $args{method};
    die "add_method: '$args{method}' is not an HTTP method PVE dispatches\n"
        if $args{method} !~ m/\A(?:GET|POST|PUT|DELETE)\z/;

    _check_permissions($id, \%args);

    # Registration is process-global, and register_method dies on a duplicate.
    # An extension listed twice, or a module loaded under two names, must not be
    # able to take pvedaemon down over it.
    my $key = join(' ', $class, $args{method}, $args{path});
    if (exists $methods{$key}) {
        log_debug("$id: $args{method} $class/$args{path} is already registered");
        return $methods{$key};
    }

    # Keep the exact reference: register_method decorates it in place, and the
    # post-check below compares against what find_handler hands back.
    my $info = {%args};
    $class->register_method($info);
    $methods{$key} = 1;

    my $probe = $self->{probes}{$class};
    if (!defined $probe) {
        # A class the extension mounted somewhere of its own accord, or nested
        # under one it did mount. Nothing to check against, so say so once
        # rather than pretending the route was verified.
        log_debug("$id: registered $args{method} $class/$args{path};"
            . ' not checking the live route, this class was not mounted by proxmod');
        return 1;
    }

    my $full = join('/', $probe, $args{path});
    $full =~ s{/+\z}{};
    $methods{$key} = $full;
    push @routes, { id => $id, class => $class, method => $args{method},
        path => $args{path}, route => $full };

    # The post-check. Everything above is about registration succeeding; this is
    # about the endpoint being reachable, which is a different question — a path
    # behind a greedy `fragmentDelimiter => ''` subtree registers perfectly and
    # then never resolves [PVE-F-051].
    my ($resolved, $resolved_info) = _resolve($args{method}, $full);
    if (!defined $resolved) {
        log_warn("$id: registered $args{method} $args{path} on $class, but a request"
            . " to it does not resolve to any handler; the endpoint is unreachable");
    } elsif ($resolved ne $class) {
        log_warn("$id: registered $args{method} $args{path} on $class, but a request"
            . " to it resolves to $resolved; the endpoint is shadowed");
    } elsif (!defined $resolved_info || $resolved_info != $info) {
        my $other = (defined $resolved_info && defined $resolved_info->{name})
            ? $resolved_info->{name} : 'something else';
        log_warn("$id: registered $args{method} $args{path} on $class, but a request"
            . " to it is answered by '$other' on the same class; the endpoint is shadowed");
    } else {
        log_debug("$id: $args{method} $args{path} on $class is reachable");
    }

    return $full;
}

# A method with no `permissions` key is not an error to Proxmox — it is a
# working endpoint that only root@pam may call, with nothing said about it
# anywhere [PVE-F-050]. proxmod makes the choice explicit instead: pass
# `permissions => undef` and you get PVE's root-only default, deliberately.
sub _check_permissions {
    my ($id, $args) = @_;

    die "add_method: every method must carry a 'permissions' key."
        . " Pass `permissions => undef` for root\@pam-only, `{ user => 'all' }`"
        . " for any authenticated user, or `{ check => [...] }` for an ACL check.\n"
        if !exists $args->{permissions};

    my $perm = $args->{permissions};
    return if !defined $perm;

    die "add_method: 'permissions' must be a hash reference or undef\n"
        if ref($perm) ne 'HASH';

    die "add_method: 'permissions' needs a 'user' or a 'check'\n"
        if !defined $perm->{user} && !defined $perm->{check};

    if (defined $perm->{user}) {
        die "add_method: permissions user '$perm->{user}' is not one PVE understands"
            . " ('all' or 'world')\n"
            if $perm->{user} !~ m/\A(?:all|world)\z/;

        # 'world' means the endpoint is reachable with no login at all. PVE uses
        # it for the ticket endpoint. An extension almost never wants it, and if
        # it does, an administrator should be able to find out from the journal.
        log_warn("$id: $args->{name} is registered with permissions user => 'world';"
            . ' it can be called without authenticating')
            if $perm->{user} eq 'world';
    }

    return;
}

# ---------------------------------------------------------------------------
# Wrapping a Proxmox seam
# ---------------------------------------------------------------------------
#
# ADR 0001 chose runtime injection over patching Proxmox's files, and
# conventions.md §3 states the rule that follows from it — "probe before you
# wrap; a seam that moved should produce a missing feature and a log line, never
# a stuck interface". Until now that was prose, and every extension implemented
# it by hand, differently.
#
# Two kinds of seam, because Proxmox offers two:
#
#   method  a PVE API method, reached through its live $info hashref.
#           map_method_by_name returns the SAME hashref register_method was
#           given, handle() reads $info->{code} on every call, and AUTOLOAD
#           closes over that hashref when it lazily installs the class method
#           [PVE-F-054] — so replacing that one field covers
#           $class->handle($info, ...) and $class->method_name(...) at once.
#           Only `code` is touched: the schema, permissions, protected flag and
#           return type are Proxmox's, and a wrap that changed them would be a
#           compatibility break dressed up as a policy.
#
#   sub     a plain named function, replaced in the symbol table. This is what
#           the frontend injection uses, and what an extension reaches for when
#           the seam is not an API method at all.
#
# POSTURE IS MANDATORY AND HAS NO DEFAULT, for the same reason `permissions` is
# (ADR 0006, ADR 0012): a hook that dies either refuses the wrapped call or is
# swallowed, those are opposites, and neither is safe to assume on the author's
# behalf.
#
#   closed  a hook that dies propagates, and the wrapped call never runs.
#           What enforcement needs.
#   open    a hook that dies is caught and logged, and the original runs
#           regardless — "our half is optional; theirs is not".

my $RE_NAME = qr/\A([A-Za-z_][A-Za-z0-9_]*)\z/;

our %POSTURES = (closed => 1, open => 1);

# Wrap a PVE API method by replacing the `code` ref on its live $info hashref.
#
#     $api->wrap_method(
#         class   => 'PVE::API2::Qemu',
#         name    => 'create_vm',
#         posture => 'closed',
#         daemons => ['pvedaemon'],
#         before  => sub { my ($args) = @_; ... },   # $args->[0] is $param
#     );
#
# Returns the seam id. Idempotent: wrapping the same seam twice is a no-op, not
# a second layer that would run every hook twice.
sub wrap_method {
    my ($self, %args) = @_;

    return _wrap($self->{id}, $self->{daemon}, 'method', %args);
}

# Wrap a plain named sub in the symbol table. Takes `package` where wrap_method
# takes `class`; otherwise identical.
sub wrap_sub {
    my ($self, %args) = @_;

    return _wrap($self->{id}, $self->{daemon}, 'sub', %args);
}

# The shared implementation, taking an extension id rather than an object, so
# that proxmod itself — Proxmod::Frontend — can use it for its own seams without
# inventing an API object it has no other use for.
sub _wrap {
    my ($ext, $daemon, $kind, %args) = @_;

    # wrap_sub spells it `package`, because a plain sub does not live in a
    # class. Normalised here rather than in the caller so that both public
    # entry points and proxmod's own internal use agree.
    $args{class} = delete $args{package} if exists $args{package};

    my $class = $args{class};
    die "$kind wrap: a class is required\n" if !defined $class || $class eq '';

    my ($clean_class) = ($class =~ $RE_PACKAGE);
    die "$kind wrap: '$class' is not a valid package name\n" if !defined $clean_class;
    $class = $clean_class;    # untainted [PVE-F-042]

    my $name = $args{name};
    die "$kind wrap: a name is required\n" if !defined $name || $name eq '';

    my ($clean_name) = ($name =~ $RE_NAME);
    die "$kind wrap: '$name' is not a valid sub name\n" if !defined $clean_name;
    $name = $clean_name;

    my $posture = $args{posture};
    die "$kind wrap: every wrap must carry a 'posture'. Pass 'closed' for a hook"
        . " whose death refuses the wrapped call, or 'open' for one whose death is"
        . " logged and ignored. There is no default because the two are opposites.\n"
        if !defined $posture || !$POSTURES{$posture};

    my $before = $args{before};
    my $after = $args{after};

    die "$kind wrap: 'before' must be a CODE reference\n"
        if defined $before && ref($before) ne 'CODE';
    die "$kind wrap: 'after' must be a CODE reference\n"
        if defined $after && ref($after) ne 'CODE';
    die "$kind wrap: give a 'before' or an 'after'; a wrap that does neither is"
        . " a slower call to the same function\n"
        if !defined $before && !defined $after;

    my $id = defined $args{id} && $args{id} ne '' ? $args{id} : "${class}::${name}";

    # Idempotent, the same way mount and add_method are. An extension listed
    # twice, or a module loaded under two names, must not end up with two layers
    # of wrap charging every hook twice.
    my $key = join(' ', $kind, $class, $name);
    if (my $prev = $seam_seen{$key}) {
        log_debug("$ext: $class\::$name is already wrapped");
        return $prev->{id};
    }

    my $record = {
        id => $id,
        ext => $ext,
        kind => $kind,
        class => $class,
        name => $name,
        posture => $posture,
        wrapped => 0,
        reason => undef,
    };

    push @seams, $record;
    $seam_seen{$key} = $record;

    # A seam that belongs in one daemon and not another. proxmod knows which
    # daemon it is, so every consumer would otherwise branch on $api->daemon by
    # hand — and a seam skipped for this reason is not a seam that is missing,
    # which is why the ledger records the difference rather than one `wrapped: 0`
    # for both.
    if (my $daemons = $args{daemons}) {
        my $here = defined $daemon ? $daemon : 'unknown';

        if (!grep { $_ eq $here } @$daemons) {
            $record->{reason} = "not installed in $here; this seam is for "
                . join(', ', @$daemons);
            log_debug("$ext: $id not wrapped here ($record->{reason})");
            return $id;
        }
    }

    # Its own probe and its own eval. A seam that is not found is logged ONCE
    # and left unwrapped — never guessed at, never approximated by wrapping a
    # nearby method, and never a reason to refuse installing the others. A PVE
    # upgrade that moves one method costs that one feature.
    my $ok = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        _install($record, $before, $after);
        1;
    };

    if (!$ok) {
        my $err = $@ || 'unknown error';
        $err =~ s/\s+$//;
        $err =~ s/\s*\n\s*/ /g;

        $record->{reason} = $err;

        log_warn("$ext: seam $id was not wrapped: $err."
            . ' Whatever depended on it is not happening; the other seams are'
            . ' unaffected');

        return $id;
    }

    $record->{wrapped} = 1;
    log_debug("$ext: wrapped $kind $class\::$name ($posture)");

    return $id;
}

sub _install {
    my ($record, $before, $after) = @_;

    my ($class, $name) = ($record->{class}, $record->{name});

    if ($record->{kind} eq 'method') {
        die "$class is not loaded, or is not a PVE::RESTHandler subclass\n"
            if !$class->can('map_method_by_name');

        # Dies "no such method" if the seam moved, which is the clean refusal we
        # want rather than a guess at a nearby name.
        my $info = $class->map_method_by_name($name);

        die "the method has no code reference\n" if ref($info->{code}) ne 'CODE';

        # The ONE field touched [PVE-F-054].
        $info->{code} = _wrapper($record, $info->{code}, $before, $after);

        return;
    }

    my $orig = $class->can($name);

    die "$class has no $name() to wrap; this is not a Proxmox VE we know\n"
        if ref($orig) ne 'CODE';

    {
        no strict 'refs';    ## no critic (ProhibitNoStrict)
        no warnings qw(redefine once);    ## no critic (ProhibitNoWarnings)
        *{"${class}::${name}"} = _wrapper($record, $orig, $before, $after);
    }

    return;
}

sub _wrapper {
    my ($record, $orig, $before, $after) = @_;

    my $closed = $record->{posture} eq 'closed';

    return sub {
        my @args = @_;

        _hook($record, 'before', $closed, sub { $before->(\@args) }) if $before;

        # Context is propagated rather than forced. Calling the original in list
        # context and handing back $ret[0] would quietly change what a method
        # returning a list means in scalar context, and this facility is pointed
        # at code nobody here wrote.
        if (wantarray) {
            my @ret = $orig->(@args);
            _hook($record, 'after', $closed, sub { $after->(\@args, \@ret) }) if $after;
            return @ret;
        }

        my $ret = $orig->(@args);
        _hook($record, 'after', $closed, sub { $after->(\@args, [$ret]) }) if $after;
        return $ret;
    };
}

sub _hook {
    my ($record, $which, $closed, $code) = @_;

    # closed: a hook that dies refuses the wrapped call, and the caller sees
    # why. That is the whole point of the posture and it must not be softened.
    return $code->() if $closed;

    my $ok = eval {
        local $SIG{__DIE__} = 'DEFAULT';
        $code->();
        1;
    };

    return 1 if $ok;

    my $err = $@ || 'unknown error';
    $err =~ s/\s+$//;
    $err =~ s/\s*\n\s*/ /g;

    # proxmod's own seams need no owner prefix: Proxmod::Log already stamps
    # every line with "proxmod:", and doubling it reads like a bug.
    my $who = $record->{ext} eq $SEGMENT ? '' : "$record->{ext}: ";

    log_error("$who$record->{id} wrapper failed ($which hook), serving Proxmox's"
        . " own answer: $err");

    return 0;
}

# Would a request to this path reach this class? Exposed because an extension
# that mounts something itself, or nests subclasses, can check its own work —
# and because proxmod-verify replays the same question against a live daemon.
sub assert_route {
    my ($self, $method, $path, $expect) = @_;

    my ($resolved) = _resolve($method, $path);

    return (1, "$method $path is served by $expect")
        if defined $resolved && defined $expect && $resolved eq $expect;

    return (0, "$method $path does not resolve to any handler")
        if !defined $resolved;

    return (0, "$method $path is served by $resolved, not $expect");
}

1;
