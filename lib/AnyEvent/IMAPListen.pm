package AnyEvent::IMAPListen;

use common::sense;
use base qw/Object::Event/;

use AnyEvent;
use AnyEvent::Handle;
use IO::Socket::SSL;
use Mail::IMAPClient;

our $VERSION = '0.03';
our $INTERVAL = 300;

=head1 NAME

AnyEvent::IMAPListen

=head1 SYNOPSIS

  use AnyEvent::IMAPListen;
  # パラメータはMail::IMAPClientと同じで、
  # on_notify, on_error, on_connect, handle_notify
  # のメソッドを追加で定義できるようになっている
  my $listener; $listener = AnyEvent::IMAPListen->new(
      Server    => 'imap.gmail.com',
      Port      => 993,
      User      => 'aaaa',
      Password  => 'xxxxxx',
      Ssl       => 1,
      Uid       => 1,
      Debug     => 1,
      on_notify => sub { # if mail comes
          my ($self, $header, $msg_id) = @_;
      },
      on_error => sub {
          my ($self, $e_error, $l_error) = @_;
      }
  )->start;

  AE::cv->wait;

=cut

sub new {
    my $pkg = shift;
    my %args = ($_[1]) ? @_ : %{$_[1]};

    $args{Server} or die "no server name\n";
    $args{Port}   or die "no port number\n";

    my $on_connect = delete $args{on_connect} || sub {
        my $self = shift;
        warn "[DEBUG] connected\n" if $self->debug;
    };
    my $on_error = delete $args{on_error} || sub {
        my $self = shift;
        warn "[DEBUG] error\n" if $self->debug;
    };
    my $on_notify = delete $args{on_notify} || sub {
        my $self = shift;
        warn "[DEBUG] notify\n" if $self->debug;
    };
    my $handle_notify  = delete $args{handle_notify}  || sub {
        my $self  = shift;
        my $msgid = shift or return;
        my $header = $self->imap->parse_headers($msgid, 'ALL');
        $self->event(on_notify => $header, $msgid);
    };

    my $instance = bless { imap => undef, args => \%args, _ae => {} }, $pkg;

    $instance->reg_cb(on_connect => $on_connect);
    $instance->reg_cb(on_error   => $on_error);
    $instance->reg_cb(on_notify  => $on_notify);
    $instance->reg_cb(handle_notify => $handle_notify);

    $instance;
}

sub imap (;$) {
    if (@_ > 1) {
        $_[0]->{imap} = $_[1];
    }
    $_[0]->{imap}
}

sub debug (;$) {
    if (@_ > 1) {
        $_[0]->imap->Debug($_[1]);
    }
    $_[0]->imap->Debug;
}

sub ae (;$) {
    if (@_ > 1) {
        return $_[0]->{_ae}{$_[1]};
    }
    $_[0]->{_ae};
}

sub reg_ae ($$;$@) {
    my $self = shift;
    my ($name, @args) = @_;
    if (ref($args[0]) =~ /^(AnyEvent|AE)/) {
        $self->{_ae}{$name} = $args[0];
    }
    else {
        my $f = "AE::${name}";
        $self->{_ae}{$name} = &$f(@args);
    }
}

sub unreg_ae ($;@) {
    my $self = shift;
    if (@_) {
        delete $self->{_ae}{$_} for @_;
    }
    else {
        $self->{_ae} = undef;
    }
}

sub start() {
    my $self = shift;

    my $noop_interval;
    if ($self->{args}->{noop_interval}) {
        $noop_interval = delete $self->{args}->{noop_interval} || $INTERVAL;
    }
    else {
        $noop_interval = $INTERVAL;
    }

    my $server = delete $self->{args}{Server};
    my $port   = delete $self->{args}{Port};

    my ($hdl, $socket, $connect, $read);
    my ($idle, %cached_msgs);

    $connect = sub {
        $self->{imap} = undef;
        $socket = undef if $socket;
        $hdl    = $self->{_ae}{handle} = undef;

        $socket = IO::Socket::SSL->new(
            PeerAddr => $server,
            PeerPort => $port,
        ) or die "socket(): $@";

        $hdl = AnyEvent::Handle->new(
            fh       => $socket,
            on_error => sub {
                warn "[DEBUG] error!\n" if $self->imap && $self->imap->Debug;
                $connect->();
            },
            on_read  => $read,
            on_eof   => sub {
                warn "[DEBUG] EOF!\n" if $self->imap && $self->imap->Debug;
                $connect->();
            },
        );

        $self->imap(Mail::IMAPClient->new(%{ $self->{args} }, Socket => $hdl->fh))
            or die "Could not connect to IMAP server";
        $self->imap->select("inbox");
        $self->event(on_connect => $self->imap);

        $self->reg_ae(handle => $hdl);
    };

    $read = sub {
        my $imap = $self->imap;
        my $s = $self->imap->Socket;
        my $line = <$s>;
        if ($line =~ /EXISTS/) {
            $imap->done($idle);
            warn "[DEBUG] notify!\n" if $imap->Debug;
            eval {
                for my $msgid (grep { !$cached_msgs{$_} } @{ $imap->unseen }) {
                    $cached_msgs{$msgid} = 1;
                    warn "[DEBUG] id: ${msgid}\n" if $imap->Debug;
                    $self->event(handle_notify => $msgid);
                }
            };
            if ($@) {
                $self->event(on_error => $@, $imap->LastError, $imap);
            }
            $idle = $imap->idle;
        }
    };

    $connect->();

    $self->reg_ae(timer => $noop_interval, $noop_interval, sub {
        my $imap = $self->imap;
        warn "[DEBUG] keep connection ".AE::now()."\n" if $imap->Debug;
        $imap->done($idle);
        %cached_msgs = map { $_ => 1 } @{ $imap->unseen };
        $idle = $imap->idle;
        AE::now_update;
    });

    $self;
}


1;
__END__

=head1 AUTHOR

taiyoh E<lt>sun.basix@gmail.comE<gt>

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
