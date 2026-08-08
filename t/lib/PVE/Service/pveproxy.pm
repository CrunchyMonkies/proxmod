package PVE::Service::pveproxy;

use strict;
use warnings;

use HTTP::Headers;
use HTTP::Response;

# A stand-in for the pveproxy daemon class, shaped like the real one where
# Proxmod::Frontend touches it and empty everywhere else.
#
# PROVENANCE. The two seams below are copied from pve-manager 9.1.1,
# /usr/share/perl5/PVE/Service/pveproxy.pm:
#
#   sub init  builds $self->{server_config}, whose {pages} and {dirs} keys are
#             what PVE::APIServer::AnyEvent routes on (:63, :123-136)
#   sub get_index($nodename, $server, $r, $args)  renders a template into an
#             HTTP::Response and returns it (:206, :304-309)
#
# The shapes matter and the bodies do not: Frontend wraps these, so a test that
# invented a different signature would prove nothing. Do not "tidy" the argument
# lists.

# What get_index hands back. The tests set this to a real vendored template so
# the injection is exercised against Proxmox's own markup rather than a fixture
# written to make it pass.
our $BODY = "<html><head></head><body></body></html>\n";

# Set by init(), read by AnyEvent in production and by the tests here.
sub new {
    my ($class) = @_;
    return bless { nodename => 'n1' }, $class;
}

sub init {
    my ($self) = @_;

    # A deliberately non-empty starting point: Frontend must add to these, not
    # replace them.
    $self->{server_config} = {
        base_handler_class => 'PVE::API2',
        dirs => { '/pve2/css/' => '/usr/share/pve-manager/css/' },
        pages => {
            '/' => sub { return get_index($self->{nodename}, @_) },
            '/favicon.ico' => { file => '/usr/share/pve-manager/images/favicon.ico' },
        },
    };

    $self->{init_called} = ($self->{init_called} || 0) + 1;

    return $self;
}

sub get_index {
    my ($nodename, $server, $r, $args) = @_;

    my $headers = HTTP::Headers->new(Content_Type => 'text/html; charset=utf-8');

    return HTTP::Response->new(200, 'OK', $headers, $BODY);
}

1;
