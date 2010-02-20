package AnyEvent::IMAPListen;

use common::sense;
use utf8;
use base qw/Object::Event/;

use AnyEvent;
use Mail::IMAPClient;

our $VERSION = '0.01';
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

sub reg_ae ($@) {
    my $self = shift;
    my ($name, @args) = @_;
    my $f = "AE::${name}";
    push @{ $self->{_ae}{$name} }, &$f(@args);
}

sub start() {
    my $self = shift;

    my $args = delete $self->{args};
    my $noop_interval = delete $args->{noop_interval} || $INTERVAL;

    $self->imap(Mail::IMAPClient->new(%$args))
        or die "Could not connect to IMAP server";

    $self->imap->select("inbox");
    $self->event(on_connect => $self->imap);
    $self->handle_on_connected($noop_interval);

    $self;
}

sub handle_on_connected {
    my $self     = shift;
    my $interval = shift || $INTERVAL;

    my $imap = $self->imap;

    my ($idle, %cached_msgs);

    $idle = $imap->idle or warn "Couldn't idle: $@\n";

    $self->reg_ae(io => $imap->Socket, 0 , sub {
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
    });

    $self->reg_ae(timer => $interval, $interval, sub {
        warn "[DEBUG] noop ".AE::now()."\n" if $imap->Debug;
        $imap->done($idle);
        %cached_msgs = map { $_ => 1 } @{ $imap->unseen };
        $idle = $imap->idle;
    });
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
