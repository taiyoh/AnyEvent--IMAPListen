package AnyEvent::IMAPListen;

use common::sense;
use base qw/Object::Event/;

use AnyEvent;
use AnyEvent::Handle;
use IO::Socket::SSL;
use Mail::IMAPClient;

our $VERSION = '0.040';
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

    my $instance = bless { imap => undef, args => \%args }, $pkg;

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

do {
    my %idle;
    my %cache;
    my %ae;

    sub idle_start {
        my $self = shift;
        $idle{$self+0} = $self->imap->idle
    }

    sub idle_stop {
        my ($self) = @_;
        $self->imap->done($idle{$self+0});
        $idle{$self+0} = undef;
    }

    sub _update_cache {
        my $self = shift;
        $cache{$self+0} = +{ map { $_ => 1 } @_ };
    }

    sub _add_cache {
        my $self = shift;
        $cache{$self+0}{$_[0]} = 1;
    }

    sub _has_cache {
        my $self = shift;
        !!$cache{$self+0}{$_[0]};
    }

    sub ae (;$) {
        my ($self, $key) = @_;
        if ($key) {
            return $ae{$self+0}{$key};
        }
        $ae{$self+0};
    }

    sub reg_ae ($$;$@) {
        my $self = shift;
        my ($name, @args) = @_;
        if (ref($args[0]) =~ /^(AnyEvent|AE)/) {
            $ae{$self+0}{$name} = $args[0];
        }
        else {
            my $f = "AE::${name}";
            $ae{$self+0}{$name} = &$f(@args);
        }
        return $ae{$self+0}{$name};
    }

    sub unreg_ae ($;@) {
        my $self = shift;
        if (@_) {
            delete $ae{$self+0}{$_} for @_;
        }
        else {
            $ae{$self+0} = undef;
        }
        return undef;
    }

    sub DESTROY {
        my $self = shift;
        $idle{$self+0}  = undef;
        $cache{$self+0} = undef;
        $ae{$self+0}    = undef;
    }
};

sub on_read_proc {
    my ($self, $line) = @_;
    my $imap = $self->imap;
    warn "[DEBUG] notify!\n" if $imap->Debug;
    eval {
        for my $msgid (grep { !$self->_has_cache($_) } @{ $imap->unseen }) {
            $self->_add_cache($msgid);
            warn "[DEBUG] id: ${msgid}\n" if $imap->Debug;
            $self->event(handle_notify => $msgid);
        }
    };
    if ($@) {
        $self->event(on_error => $@, $imap->LastError, $imap);
    }
}

sub interval_proc {
    my $self = shift;
    my $imap = $self->imap;
    warn "[DEBUG] keep connection <$self->{args}{User}> ".AE::now()."\n" if $imap->Debug;
    $self->_update_cache(@{ $imap->unseen });
    AE::now_update;
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

    my ($hdl, $socket, $connect);

    $connect = sub {
        $self->{imap} = $socket = $hdl = $self->unreg_ae('handle');

        $socket = IO::Socket::SSL->new(
            PeerAddr => $server,
            PeerPort => $port,
        ) or die "socket(): $@";

        $hdl = AnyEvent::Handle->new(
            fh       => $socket,
            on_read  => sub {
                my $s = shift->fh;
                my $line = <$s>;
                return if $line !~ /EXISTS/;
                $self->idle_stop;
                $self->on_read_proc($line);
                $self->idle_start;
            },
            on_error => sub {
                warn "[DEBUG] error!\n" if $self->imap && $self->imap->Debug;
                $connect->();
            },
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
        $self->idle_start;
    };

    $connect->();

    $self->reg_ae(timer => $noop_interval, $noop_interval, sub {
        $self->idle_stop;
        $self->interval_proc;
        $self->idle_start;
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
