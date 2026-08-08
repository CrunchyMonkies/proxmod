package ProxmodExample::Hello;

use strict;
use warnings;

use PVE::RESTHandler;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::RESTHandler);

# The reference backend extension. Everything an extension is allowed to do is
# done here once, with the reasoning attached; everything it is not allowed to
# do is called out where it would be tempting.
#
# Note what is NOT here: no PVE file is patched, no PVE module is loaded early
# to be monkey-patched, and there are no maintainer scripts in this package at
# all. It ships three files and depends on proxmod. See ../README.md.
#
# `use base qw(PVE::RESTHandler)` is a compile-time dependency on Proxmox, and
# that is fine: this module is only ever loaded by Proxmod::Backend from inside
# a running pvedaemon or pveproxy, where PVE::RESTHandler is already compiled.
# proxmod's own modules may not do this — they have to load in proxmod-verify
# and under a bare `perl -c` too — but an extension has no such obligation.

our $VERSION = '0.1.0';

# The entry point Proxmod::Backend calls, once, with an API object scoped to
# this extension. Its name is the whole contract.
#
# Anything that dies in here costs this extension and nothing else: Backend runs
# it inside its own eval and logs the failure. That is deliberate licence to
# fail loudly rather than to paper over a problem.
sub proxmod_register {
    my ($api) = @_;

    # Claim this extension's subtree. The path is not ours to choose — it is
    # /nodes/{node}/proxmod/<id>, where <id> comes from the manifest — which is
    # exactly why two extensions can never collide.
    $api->mount(scope => 'node', subclass => __PACKAGE__);

    _register_index($api);
    _register_greet($api);
    _register_note($api);

    return;
}

sub _register_index {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'index',
        path => '',
        method => 'GET',
        # 'all' is any authenticated user. Note that this is not the same as
        # leaving `permissions` out: omitting it means root@pam only, silently
        # [PVE-F-050]. proxmod refuses to register a method without the key so
        # that the choice is always visible in the source.
        permissions => { user => 'all' },
        description => 'Index of the proxmod hello example.',
        parameters => {
            additionalProperties => 0,
            properties => {
                node => get_standard_option('pve-node'),
            },
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
            return [{ subdir => 'greet' }, { subdir => 'note' }];
        },
    );

    return;
}

sub _register_greet {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'greet',
        path => 'greet',
        method => 'GET',
        # A real ACL check. '{node}' is substituted from the request's own
        # parameters before the check runs, so this reads as "may this user
        # audit THIS node", not "may they audit some node".
        permissions => {
            check => ['perm', '/nodes/{node}', ['Sys.Audit']],
        },
        description => 'Say hello, and report something about the node.',
        parameters => {
            additionalProperties => 0,
            properties => {
                node => get_standard_option('pve-node'),
                name => {
                    type => 'string',
                    description => 'Who to greet.',
                    maxLength => 64,
                    optional => 1,
                },
            },
        },
        returns => {
            type => 'object',
            properties => {
                message => { type => 'string' },
                node => { type => 'string' },
                loadavg => { type => 'number' },
            },
        },
        code => sub {
            my ($param) = @_;

            # $param has been validated against the schema above and untainted
            # by PVE::RESTHandler::handle before reaching here. That is true of
            # the declared parameters only — anything this method reads from
            # elsewhere is still its own problem.
            my $who = defined $param->{name} ? $param->{name} : 'world';

            return {
                message => "hello, $who",
                node => $param->{node},
                loadavg => _loadavg(),
            };
        },
    );

    return;
}

sub _register_note {
    my ($api) = @_;

    $api->add_method(
        class => __PACKAGE__,
        name => 'note',
        path => 'note',
        method => 'POST',
        # protected => 1 is the bridge to root. pveproxy runs as www-data and
        # cannot write below /var/lib; marking the method protected makes
        # pveproxy forward the whole request to pvedaemon, which runs as root
        # and executes it there. Nothing else is needed to cross that boundary
        # — and nothing less will do, which is why an extension that "works
        # when I run it as root" often fails for everyone else.
        protected => 1,
        permissions => {
            check => ['perm', '/nodes/{node}', ['Sys.Modify']],
        },
        description => 'Store a short note on this node, as root.',
        parameters => {
            additionalProperties => 0,
            properties => {
                node => get_standard_option('pve-node'),
                text => {
                    type => 'string',
                    description => 'The note to store.',
                    maxLength => 512,
                },
            },
        },
        returns => { type => 'null' },
        code => sub {
            my ($param) = @_;

            # /var/lib/proxmod is created by the proxmod package. An extension
            # writes under a directory it or proxmod owns — never into /etc/pve,
            # which is a FUSE filesystem that is unmounted during upgrades and
            # is not a place to keep an extension's own state.
            my $dir = '/var/lib/proxmod';
            my $file = "$dir/example-hello.note";

            open(my $fh, '>', $file)
                or die "cannot write $file: $!\n";
            print {$fh} $param->{text}, "\n";
            close($fh)
                or die "cannot write $file: $!\n";

            return;
        },
    );

    return;
}

sub _loadavg {
    open(my $fh, '<', '/proc/loadavg') or return 0;
    my $line = <$fh>;
    close($fh);

    return 0 if !defined $line;

    # Untainted by capture: this came off the filesystem, and the daemons run
    # under -T [PVE-F-002]. It is also about to be validated as a number by the
    # returns schema, which is a check, not an excuse to skip this one.
    my ($one) = ($line =~ m/\A(\d+\.\d+)\s/);

    return defined $one ? 0 + $one : 0;
}

1;
