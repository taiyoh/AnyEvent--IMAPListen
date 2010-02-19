#!/usr/bin/env perl

use common::sense;
use utf8;

use FindBin::libs;

use AnyEvent::IMAPListen;
use AnyEvent::HTTP;
use HTTP::Request::Common;
use Config::Pit;
use Encode;
use Digest::SHA qw/sha1_hex/;

use YAML;

my %im_kayac = %{ pit_get('im.kayac') };
my ($skey, $user) = @im_kayac{qw/SecretKey user/};

# パラメータはMail::IMAPClientとほぼ同じ
my $listener; $listener = AnyEvent::IMAPListen->new(
    Server    => 'imap.gmail.com',
    Port      => 993,
    %{ pit_get('imap.notify') },
    Ssl => 1,
    Uid => 1,
    Debug => 1,
    on_notify => sub { # if mail comes
        my ($self, $header) = @_;

        my $from = $header->{From}->[0];
        my $subj = $header->{Subject}->[0];

        ($from = decode('MIME-Header', $from)) =~ s{ <.+?>$}{};
        $subj  = decode('MIME-Header', $subj);

        my $msg = sprintf('[mail][mobile] from:%s subject:%s', $from, $subj);
        my $req = POST "http://im.kayac.com/api/post/${user}", [
            message => $msg, sig => sha1_hex("${msg}${skey}")
        ];
        my %headers = map { $_ => $req->header($_), } $req->headers->header_field_names;

        my $r;
        eval { $r = http_post $req->uri, $req->content, headers => \%headers, sub { undef $r }; };
        if ($@) {
            warn "[DEBUG][ERROR]", YAML::Dump($@) if $self->debug;
        }
    },
    on_error => sub {
        my ($self, $e_error, $l_error) = @_;
        warn YAML::Dump([$e_error, $l_error]) if $listener->debug;
    }
)->start;

AE::cv->recv;
