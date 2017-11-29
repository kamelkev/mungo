package Mungo::Response;

# Copyright (c) 2007 OmniTI Computer Consulting, Inc. All rights reserved.
# For information on licensing see:
#   https://labs.omniti.com/zetaback/trunk/LICENSE

=head1 NAME

Mungo::Response - Represent response side of HTTP request cycle

=head1 SYNOPSIS

  <!-- You get a Response object for free when you use Mungo -->
  <% if ($Response) { ... } %>

  <!-- Read and Mungo-process other files -->
  <%
     # Prints to browser
     $Response->Include('/some/file.html', $arg1);

     # Caputured
     my $output = $Response->TrapInclude('/some/file.html');

     # Can also print to browser via Response
     print $Response "Hello world!";
  %>

  <!-- May also set headers -->
  <%
     $Response->AddHeader('header_name' => $value);
  %>

  <!-- path of the current file (handy for debugging) -->
  <% my $file = $Response->CurrentFile(); %>


  <!-- Halt processing and jump out of the handler -->
  <%
     # With a 302
     $Response->Redirect('/new/url/');

     # Just end
     $Response->End();
  %>

  <!-- Cookie facility -->
  <%
     # Single valued cookies
     $Response->Cookies($cookie_name, $cookie_value);

     # Multivalued cookies
     $Response->Cookies($cookie_name, $key, $value);

     # Cookie options
     $Response->Cookies($cookie_name, 'Domain', $value);
     $Response->Cookies($cookie_name, 'Expires', $value);
     $Response->Cookies($cookie_name, 'Path', $value);
     $Response->Cookies($cookie_name, 'Secure', $value);

     # See perldoc Mungo::Cookie for more details
  %>

=head1 DESCRIPTION

Represents the response side of the Mungo request cycle.  All operations related to output are contained in this object.

=head2 OUTPUT BUFFERING

By default, output is not buffered.  Output (resulting from print() statements or <%= %> tags) is immediately sent to the browser.  Mungo does support a buffering mechanism, in which the entire contents of the response (or sub-include) are collected before the first character is output.  The buffer does not have a size limit, other than practical limits of your machine; nor is it chunked in any way.

You can enable buffering in two ways.  From within httpd.conf, you can use the MungoBuffer Perl variable:

  # Can use Directory, Files, Location, etc.
  <Directory /www/slowboat>
     # Any Perlishly true value will work
     SetPerlVar MungoBuffer 1
  </Directory>

Additionally, you can enable (or disable) buffering within a particular request-response cycle:

  <%
     # Decide to turn on buffering
     $Response->{Buffer} = 1;
  %>

Disabling buffering (when it was previously enabled) will cause an immediate flush.

At the end of the request, the buffer is flushed in its entirety.

If you enable buffering at the top-level page, you can add headers throughout the response, even after generating output.  Without buffering, this would normally be an error.  This advantage does not apply to sub-includes.  Of course, if you generated output and then later enabled buffering, you cannot later add headers.

=head1 METHODS

=cut


use strict;
use IO::Handle;
use Mungo::Arbiter::Response;
use Mungo::Response::Trap;
use Mungo::Cookie;
use Mungo::Utils;
use HTML::Entities;
use Encode qw ( encode_utf8 );
use Apache2::Const qw ( OK NOT_FOUND DECLINED SERVER_ERROR );

our $AUTOLOAD;

our $DEBUG = 0;
use Data::Dumper;

my $one_true_buffer = '';

sub new {
  my $class = shift;
  my $parent = shift;
  my $r = $parent->{'Apache::Request'};
  my $singleton = $r->pnotes(__PACKAGE__);
  return $singleton if ($singleton);
  my %core_data = (
    'Apache::Request' => $r,
    'ContentType' => $r->dir_config('MungoContentType') || $r->content_type || 'text/html',
    # We don't set buffer here, we set it after it has been tied.
    # 'Buffer' => $r->dir_config('MungoBuffer') || 0,
    'Buffer' => 0,
    'CacheControl' => $r->dir_config('MungoCacheControl') || 'private',
    'Charset' => $r->dir_config('MungoCharset') || undef,
    'Status' => 200,
    'Mungo' => $parent,
    'CookieClass' => $r->dir_config('MungoCookieClass') || 'Mungo::Cookie',
    'Cookies' => undef, # placeholder for visibility
  );
  my %data;
  $singleton = bless \%data, $class;
  tie %data, 'Mungo::Arbiter::Response', $singleton, \%core_data;
  $singleton->{Buffer} = $r->dir_config('MungoBuffer') || 0;
  $r->pnotes(__PACKAGE__, $singleton);
  return $singleton;
}

sub DESTROY {
  my $self = shift;
  $self->cleanse();
}

sub cleanse {
  my $self = shift;
  my $_r = tied %$self;
  if(ref $_r->{data}->{'IO_stack'} eq 'ARRAY') {
    while (@{$_r->{data}->{'IO_stack'}}) {
      my $fh = pop @{$_r->{data}->{'IO_stack'}};
      close(select($fh));
    }
  }
  delete $_r->{data}->{$_} for keys %$self;
  untie %$self if tied %$self;
}

sub send_http_header {
  my $self = shift;
  my $_r = tied %$self;
  my $r = $_r->{data}->{'Apache::Request'};
  return if($_r->{data}->{'__HEADERS_SENT__'});
  $_r->{data}->{'__HEADERS_SENT__'} = 1;
  if($_r->{data}->{CacheControl} eq 'no-cache') {
    $r->no_cache(1);
  }
  else {
    if($r->can('headers_out')) {
      $r->err_headers_out->set('Cache-Control' => $_r->{data}->{CacheControl});
    }
    else {
      $r->err_header_out('Cache-Control' => $_r->{data}->{CacheControl});
    }
  }
  # Must use Internal as the tiehash is magic for cookies
  $_r->{'__Internal__'}->{Cookies}->inject_headers($r);
  $r->status($_r->{data}->{Status});
  $r->can('send_http_header') ?
    $r->send_http_header($_r->{data}->{ContentType}) :
    $r->content_type($_r->{data}->{ContentType});;
}

sub start {
  my $self = shift;
  my $_r = tied %$self;
  return if(exists $_r->{data}->{'IO_stack'} &&
            scalar(@{$_r->{data}->{'IO_stack'}}) > 0);
  $_r->{data}->{'IO_stack'} = [];
  tie *DIRECT, ref $self, $self;
  push @{$_r->{data}->{'IO_stack'}}, select(DIRECT);
}

sub finish {
  my $self = shift;
  my $_r = tied %$self;
  # Unbuffer outselves, this will actually induce a flush (must go through tiehash)
  $_r->{'__Internal__'}->{Buffer} = 0;
  untie *DIRECT if tied *DIRECT;
  return unless(exists $_r->{data}->{'IO_stack'});
  my $fh = $_r->{data}->{'IO_stack'}->[0];
  die __PACKAGE__." IO stack of wrong depth" if(scalar(@{$_r->{data}->{'IO_stack'}}) != 1);
}

=head2 $file = $Response->CurrentFile();

=head2 @nested_files = $Response->CurrentFile();

Returns the path on the filesystem from which the currently executing Mungo code originated.  In the second form, the call stack is unwound, and all files are returned, with the deepest-nested one first.  

If the Mungo code originated from a string reference rather than a file, the file entry will read 'ANON'.

=cut

sub CurrentFile {
    my $self = shift;
    return $self->{Mungo}->CurrentFile();
}

=head2 $Response->i18nHandler($coderef);

Sets the i18n translation handler for the output.  This is translate phases
(or keys) in templates annotated like I[[keyname]].  If the handler is unset
the default behaviour is to pass the keyname through so "I[[Firstname]]"
becomes "Firstname"  The handler passed in should take one argument (the key)
and return the replacement text.

=head2 $Response->i18n($text)

Runs the registered i18n handler on the supplied text returning the
translation.

=cut

sub i18nHandler {
  my $self = shift;  my $_r = tied %$self;
  $_r->{data}->{'i18n_handler'} = shift if (@_);
  return $_r->{data}->{'i18n_handler'};
}

sub i18n {
  my $self = shift;  my $_r = tied %$self;
  my $key = shift;
  my $handler = $_r->{data}->{'i18n_handler'};
  return ($handler && ref $handler eq 'CODE') ? $handler->($key) : $key;
}


=head2 $Response->AddHeader('header_name' => 'header_value');

Adds an HTTP header to the response.

Dies if headers (or any other output) has already been sent.

=cut

sub AddHeader {
  my $self = shift;
  my $_r = tied %$self;
  my $r = $_r->{data}->{'Apache::Request'};
  die "Headers already sent." if($_r->{data}->{'__HEADERS_SENT__'});
  $r->can('headers_out') ? $r->err_headers_out->set(@_) : $r->err_header_out(@_);
}
sub Cookies {
  my $self = shift;
  my $_r = tied %$self;
  die "Headers already sent." if($_r->{data}->{'__HEADERS_SENT__'});
  # Must use Internal as the tiehash is magic for cookies
  my $cookie = $_r->{'__Internal__'}->{'Cookies'};
  unless ($cookie) {
      # Ok, use the magic version to construct one.
      $cookie = $self->{'Cookies'};
  }
  $cookie->__set(@_);
}

=head2 $Response->Redirect($url);

Issues a 302 redirect with the new location as $url.

Dies if headers (or any other output) has already been sent.

=cut

sub Redirect {
  my $self = shift;
  my $url = shift;
  my $_r = tied %$self;
  die "Cannot redirect, headers already sent\n" if($_r->{data}->{'__HEADERS_SENT__'});
  $_r->{data}->{Status} = shift || 302;
  my $r = $_r->{data}->{'Apache::Request'};
  $r->can('headers_out') ? $r->err_headers_out->set('Location', $url) :
                           $r->err_header_out('Location', $url);
  $self->send_http_header();
  $self->End();
}


=head2 $res->Include($filename, $arg1, $arg2, ...);

=head2 $res->Include(\$string, $arg1, $arg2, ...);

Reads the given filename or string and interprets it as Mungo ASP code.

Any passed arguments are available in the @_ array within the ASP code.

The results of evaluating the code is printed to STDOUT.

=cut

sub Include {
    my $self = shift;
    my $subject = shift;
    my $_r = tied %$self;
    my $rv;

    if ($DEBUG > 1) {
        print STDERR __PACKAGE__ . ':' . __LINE__ . "- Have self OnError as " . $self->{data}->{OnError} . "\n";
        print STDERR __PACKAGE__ . ':' . __LINE__ . "- Have tied OnError as " . $_r->{data}->{OnError} . "\n";
    }

    eval {
        local $SIG{__DIE__} = \&Mungo::wrapErrorsInObjects;
        if(ref $subject) {
            $rv = $_r->{data}->{Mungo}->include_mem($subject, @_);
        } else {
            $rv = $_r->{data}->{Mungo}->include_file($subject, @_);
        }
    };
    if($@) {
        if ($DEBUG) { print STDERR __PACKAGE__ . ':' . __LINE__ . "- Have level one error: " . $@ . "\n"; }

        # If we have more than 1 item in the IO stack, we should just re-raise.
        if (scalar(@{$_r->{data}->{'IO_stack'} || []}) > 1) {
            local $SIG{__DIE__} = undef;
            if ($DEBUG > 1) { print STDERR __PACKAGE__ . ':' . __LINE__ . "- rethrowing\n"; }
            die $@;
        }
        my $hashref = $@;
        eval {
            if($_r->{data}->{OnError}) {
                if ($DEBUG > 1) { print STDERR __PACKAGE__ . ':' . __LINE__ . "- have custom error handler, calling\n"; }
                $_r->{data}->{OnError}->($self, $hashref, $subject);
            } else {
                if ($DEBUG > 1) { print STDERR __PACKAGE__ . ':' . __LINE__ . "- no custom error handler, using default\n"; }
                $self->defaultErrorHandler($hashref, $subject);
            }
        };
        if ($@) {
            # Oh, dear lord this is bad.  We'd died trying to print out death.
            print STDERR "Mungo::Response -> die in error renderer\n";
            print STDERR $hashref;
            print STDERR $@;
        }
        return undef;
    }
    return $rv;
}

sub defaultErrorHandler {
  use Data::Dumper;
  my $self = shift;
  my $href = shift; # Our Error
  my $subject = shift;
  my $_r = tied %$self;
  if ($DEBUG > 1) { print STDERR __PACKAGE__ . ':' . __LINE__ . "- in default error handler\n"; }

  print "Error in Include($subject):<br />\n";
  my $pkg = $href->{callstack}->[0]->[0];
  my $preamble = eval "\$${pkg}::Mungo_preamble;";
  my $postamble = eval "\$${pkg}::Mungo_postamble;";
  my $contents = eval "\$${pkg}::Mungo_contents;";
  print "<pre class=\"error\">$href->{error}</pre><br />\n";

  unless($contents) {
    my $filename = $href->{callstack}->[0]->[1];
    if(open(FILE, "<$filename")) {
      local $/ = undef;
      $$contents = <FILE>;
      close(FILE);
    }
  }

  if($contents) {
    if($_r->{data}->{'Apache::Request'}->dir_config('Debug')) {
      print Mungo::Utils::pretty_print_code($preamble, $contents, $postamble, $href->{callstack}->[0]->[2]);
    }
  } else {
    print '<pre>'.Dumper($@).'</pre>';
  }

  # Set response code to 500.  Fixes trac16
  $_r->{data}->{Status} = SERVER_ERROR;
  $self->{Mungo}->{data}->{ApacheResponseCode} = SERVER_ERROR;
}

=head2 $bool = $Response->Trapped();

Returns 1 if invoked within a TrapInclude, 0 otherwise

=cut

sub Trapped {
  my $self = shift;
  my $_r = tied %$self;
  my $stack = $_r->{data}->{'IO_stack'};
  return 1 if($stack && scalar(@$stack) > 1);
  return 0;
}

=head2 $output = $Response->TrapInclude($filename, @args);

Like Include(), but results are returned as a string, instead of being printed.

=cut

sub TrapInclude {
  my $self = shift;
  my $_r = tied %$self;
  my $output;
  my $handle = \do { local *HANDLE };
  tie *{$handle}, 'Mungo::Response::Trap', \$output;
  push @{$_r->{data}->{'IO_stack'}}, select(*{$handle});
  eval {
    $self->Include(@_);
  };
  untie *{$handle} if tied *{$handle};
  select(pop @{$_r->{data}->{'IO_stack'}});
  if($@) {
    local $SIG{__DIE__} = undef;
    die $@;
  }
  return $output;
}

=head2 $Response->End()

Stops processing the current response, shuts down the 
output handle, and jumps out of the response handler.  
No further processing will occur.

=cut

sub End {
  my $self = shift;
  my $_r = tied %$self;
  while(scalar(@{$_r->{data}->{'IO_stack'} || []}) > 1) {
    my $oldfh = select(pop @{$_r->{data}->{'IO_stack'}});
    if(my $obj = tied *{$oldfh}) {
      untie *{$oldfh};
      print $$obj;
    }
  }
  # If we have any data to write, or have written anything
  # then the ball in our court.
  # However, if we haven't, we should pass the status back
  # from the main handler so that Apache ErrorDocs wil work.
  if(($_r->{data}->{Buffer} && length($one_true_buffer)) ||
     $_r->{data}->{'__OUTPUT_STARTED__'}) {
    $self->Flush();
  }
  else {
    $self->{Mungo}->{data}->{ApacheResponseCode} = $_r->{data}->{Status};
  }
  eval { goto  MUNGO_HANDLER_FINISH; }; # Jump back to Mungo::handler()
}

sub Flush {
  my $self = shift;
  my $_r = tied %$self;
  # Flush doesn't apply unless we're immediately above STDOUT
  return if(scalar(@{$_r->{data}->{'IO_stack'} || []}) > 1);
  unless($_r->{data}->{'__OUTPUT_STARTED__'}) {
    $self->send_http_header;
    $_r->{data}->{'__OUTPUT_STARTED__'} = 1;
  }
  my $encoded = encode_utf8($one_true_buffer);
  if (@{$_r->{data}->{'IO_stack'} || []}) {
      $_r->{data}->{'IO_stack'}->[-1]->print($encoded);
  } else {
      print $encoded;
  }

  $one_true_buffer = '';
}

sub AUTOLOAD {
  my $self = shift;
  my $name = $AUTOLOAD;
  $name =~ s/.*://;   # strip fully-qualified portion
  die __PACKAGE__." does not implement $name";
}

sub TIEHANDLE {
  my $class = shift;
  my $self = shift;
  return $self;
}
sub PRINT {
  my $self = shift;
  my $output = join((defined($,)?$,:""), @_);
  return unless length($output);
  my $_r = tied %$self;
  if(scalar(@{$_r->{data}->{'IO_stack'} || []}) == 1) {
    # Buffering a just-in-time headers only applies if we
    # immediately above STDOUT
    if($_r->{data}->{Buffer}) {
      $one_true_buffer .= $output;
      return;
    }
    unless($_r->{data}->{'__OUTPUT_STARTED__'}) {
      $_r->{data}->{'__OUTPUT_STARTED__'} = 1;
      $self->send_http_header;
    }
  }
  $output = encode_utf8($output);
  if (@{$_r->{data}->{'IO_stack'} || []}) {
      $_r->{data}->{'IO_stack'}->[-1]->print($output);
  } else {
      print $output;
  }
}
sub PRINTF {
  my $self = shift;
  my $_r = tied %$self;
  if(scalar(@{$_r->{data}->{'IO_stack'} || []}) == 1) {
    # Buffering a just-in-time headers only applies if we
    # immediately above STDOUT
    if($_r->{data}->{Buffer}) {
      $one_true_buffer .= sprintf(@_);
      return;
    }
    unless($_r->{data}->{'__OUTPUT_STARTED__'}) {
      $_r->{data}->{'__OUTPUT_STARTED__'} = 1;
      $self->send_http_header;
    }
  }
  if (@{$_r->{data}->{'IO_stack'} || []}) {
      $_r->{data}->{'IO_stack'}->[-1]->printf(@_);
  } else {
      printf(@_);
  }
}
sub CLOSE {
  my $self = shift;
  my $_r = tied %$self;
  # Unbuffer outselves, this will actually induce a flush (must go through tiehash)
  $_r->{data}->{Buffer} = 0;
}
sub UNTIE { }

=head1 AUTHOR

Theo Schlossnagle

Clinton Wolfe (docs)

=cut

1;
