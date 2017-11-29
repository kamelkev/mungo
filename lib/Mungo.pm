package Mungo;

=head1 NAME

Mungo - An Apache::ASP inspired lightweight ASP framework

=head1 SYNOPSIS

 # In your httpd.conf:
 <FilesMatch "\.asp$">
   SetHandler perl-script

   PerlHandler Mungo

   # This is optional, see PREAMBLE SUPPORT below
   PerlSetVar MungoPreamble My::PreambleHandler

   # Optionally enable output buffering
   # see Mungo::Response - OUTPUT BUFFERING section
   PerlSetVar MungoBuffer 1

   # Turn this on if you want pages to recompile on each load
   #          off to cache the bytecode for performance
   <IfDefine DEVELOPMENT>
     PerlSetVar StatINC 1
   </IfDefine>
   <IfDefine PRODUCTION>
     # This is the default anyway
     PerlSetVar StatINC 0
   </IfDefine>

 </FilesMatch>

 # In asp pages:
 <html>
   <%= 1 + 1; %><!-- Output: 2 -->
   <% 1 + 1; %><!-- No Output  -->

   <!-- Variable scope extends across tags -->
   <% my $pet = 'pony'; %>
   <%= $pet %><!-- you get a pony! -->

   <!-- Can embed control structures into pages -->
   <% if ($prefer_daisies) { %>
     <h2>Here are your daisies!</h2>
   <% } else { %>
     <h2>Brown-Eyed Susans, Just For You!</h2>
   <% } %>

   <!-- For, foreach, while loops, too -->
   <% foreach my $beer_num (0..99) { %>
     <p><%= 99 - $beer_num %> bottles of beer on the wall</p>
   <% } %>

   <%
      # Write arbitrary amounts of Perl here

      # you can use modules
      # (just don't define subroutines or change packages)
      use Some::Module;

      # Access info about the request
      # TODO - DOCS
      # $Request->

      # Access info about the server
      # TODO - DOCS
      # $Server->

      # Redirect to somewhere else...
      if ($want_to_redirect) {
         $Response->Redirect($url);
         # Never reach here
      }

      # Abort further processing and close outout stream
      if ($want_to_end) {
         $Response->End;
         # Never reach here
      }
   %>

   <!-- Can also include other pages or fragments -->
   <% $Response->Include($filesystem_path); %>

   <!-- may also include args -->
   <% $Response->Include($filesystem_path, @args); %>

   <!-- If args are passed to an ASP page (or page fragment) access them via @_ -->
   <%
     # In included file
     my $arg1 = shift;
   %>

   <!-- What if you want to grab that output instead of sending to the browser? -->
   <% my $output = $Response->TrapInclude($filesystem_path, @args); %>

   <!-- You can also send a string of ASP code instead of using a file -->
   <%
     # Use a scalar reference!
     $Response->Include(\$asp, @args);
   %>

   <!-- Cookie facilities -->
   <%
     # Read cookie
     $single_value = $Request->Cookies($cookie_name);
     $hashref = $Request->Cookies($cookie_name);

     # Set cookie
     $Response->Cookies($cookie_name, $single_value);
     $Response->Cookies($cookie_name, $hash_ref);
   %>

 </html>


=head1 DESCRIPTION

=head2 What is Mungo?

Mungo is a mod_perl 1 or 2 PerlHandler module.  It allows you to 
embed Perl code directly into HTML files, using <% %> tags.

Mungo also provides Request and Response objects, similar to many ASP 
environments.  These facilities are aimed at applications needing simple, 
lightweight features.

=head2 What Mungo does:

=over 4

=item *

Allows perl to be embedded in web pages with <% %> tags.

=item *

Provides simplistic access to various aspects of the client request via a Mungo::Request object.

=item *

Provides simplistic manipulation of the response via a Mungo::Response object.

=item *

Handles query strings, post forms (urlencoded and multipart) as well as cookies. 

=back

=head2 What Mungo does not do:

=over 4

=item *

Manage sessions

=item *

XML/XSLT/etc

=back

=head2 Implementation Goals

Mungo was originally developed as a simpler, non-GPL'd Apache::ASP with far 
fewer CPAN dependencies.  It is somewhat compatible with Apache::ASP, but 
there are enough differences to warrant close attention to the docs here.

While Mungo is very simple and has a very small fetureset, the object APIs it 
does implement adhere closely to those present in Apache::ASP. So, assuming you
are not using sessions or the XML features, you should find few obstacles
in making your application run under Mungo (it could be as simple as
setting PerlHandler Mungo in your httpd.conf file).


=head2 Preamble Support

In addition to normal Apache stacked handlers, Mungo also supports a 
mechanism for inserting code to execute before every Mungo request is 
processed, while still having access to the Mungo environment.

To use this mechanism, define a Perl module as follows:

  package My::PreambleHandler;
  use strict;
  use warnings;

  use Apache2::Const qw ( OK DECLINED ); # Others as needed by your code

  sub handler {
     my $class          = shift;
     my $apache_request = shift;
     my $mungo_request  = shift;
     my $mungo_response = shift;
     my $mungo_server   = shift;

     # Determine what to do with the request, if anything

     if ( ... ) {
         # Continue normal Mungo processing
         return Apache2::Const::DECLINED;

     } elsif ( ... ) {
         # If handled entirely within the preamble, skip further Mungo work
         return Apache2::Const::OK;

     } elsif ( ... ) {
         # Returning anything other than DECLINED will 
         # skip further Mungo work - but should be informative
         # for example, if the user's credentials are bad...
         return Apache2::Const::NOT_AUTHORIZED;
     }

  }

With your preamble code in hand, you may now register this code to run on a per-location, directory, or file basis:

  <Location /restricted>
    SetHandler perl-script
    PerlSetVar MungoPreamble My::AuthorizationCheckingPreamble
    PerlHandler Mungo
  </location>

=head3 Limitations of Preambles

=over

=item Limit of one Preamble per location/file/directory stanza

If you require more flexibility, Apache stacked handlers are likely a better solution for you (though you will not have the Mungo environment setup in your stacked handler).

=item Preambles Modules will not be automatically loaded

You can add a PerlRequire directive to httpd.conf, or 'use' your preamble class in your startup.pl

=back

=cut



#=============================================================================#
#                           Implementation Notes
#=============================================================================#
# - public methods are CamelCase
# 
#=============================================================================#

use strict;
use Encode qw /encode_utf8/;
eval "
  use Apache2::Const qw ( OK NOT_FOUND DECLINED SERVER_ERROR);
  use Apache2::RequestRec;
  use Apache2::RequestUtil;
";
if($@) {
  print STDERR "mod_perl2 not found: $@";
  eval "
    use Apache;
    use Apache::Constants qw( OK NOT_FOUND );
  ";
  die $@ if $@;
}
use MIME::Base64 qw/encode_base64 decode_base64/;
use Data::Dumper;
use Digest::MD5 qw/md5_hex/;
use Mungo::Request;
use Mungo::Response;
use Mungo::Error;
use HTML::Entities;
use Encode;

use vars qw/$VERSION
            $DEFAULT_POST_BLOCK_SIZE $DEFAULT_POST_MAX_SIZE
            $DEFAULT_POST_MAX_PART $DEFAULT_POST_MAX_IN_MEMORY/;

$VERSION = "1.1.0." . (qw$Revision$)[1];

$DEFAULT_POST_BLOCK_SIZE = 1024*32;          # 32k
$DEFAULT_POST_MAX_SIZE = 0;             # unlimited post size
$DEFAULT_POST_MAX_PART = 0;             # and part size
$DEFAULT_POST_MAX_IN_MEMORY = 1024*128; # 128k

=head1 MODPERL HANDLER

  PerlHandler Mungo

When Mungo is the registered handler for a URL, it first locates the file (if
not found, apache's 404 response mechanism is triggered).  Global objects
describing the transaction are created: $Request, $Server, and $Response 
(see Mungo::Response, etc. for details) Next, the file is parsed and 
evaluated, and the results are sent to the browser. This happens using $Request->Include().

=cut

sub handler($$) {
  my ($self, $r) = @_;
  if (ref $self eq 'Apache2::RequestRec') {
    $r = $self;
    $self = __PACKAGE__;
  }
  my $preamble_class = $r->dir_config('MungoPreamble');
  # Short circuit if we can't find the file.
  return NOT_FOUND() if(! -r $r->filename);

  $self = $self->new($r) unless(ref $self);
  $self->Response()->start();
  local $SIG{__DIE__} = \&Mungo::wrapErrorsInObjects;
  eval {
    my $doit = Apache2::Const::DECLINED();
    $main::Request = $self->Request();
    $main::Response = $self->Response();
    $main::Server = $self->Server();
    if($preamble_class) {
      $doit = $preamble_class->handler($r, $self->Request(),
                                       $self->Response(), $self->Server());
    }
    $self->Response()->Include($r->filename)
      if($doit == Apache2::Const::DECLINED());
    $self->Response()->End();
  };
  if($@) {
    # print out the error to the logs
    print STDERR $@ if($@);
    # If it isn't too late, make this an internal server error
    eval { $self->Response()->{Status} = 500; $self->Response()->End() };
  }

  # gotos come here from:
  #   $Response->End()
 MUNGO_HANDLER_FINISH:
  $self->Response()->finish();
  my $code = $self->{data}->{ApacheResponseCode} || Apache2::Const::OK;
  $self->cleanse();
  undef $main::Request;
  undef $main::Response;
  undef $main::Server;
  undef $self;
  return $code; 
}


sub wrapErrorsInObjects {
  my $i = 0;
  my @callstack;
  while(my @callinfo = caller($i++)) {
    push @callstack, \@callinfo;
  }
  die Mungo::Error->new({ error => shift, callstack => \@callstack });
}

=for private_developer_docs

=head2 $mungo = Mungo->new($req);

Given an Apache2::RequestRec or Apache request object,
return the Mungo context, which is a Singleton.

Called from the modperl handler.

=cut

sub new {
  my ($class, $r) = @_;
  my $self = $r->pnotes(__PACKAGE__);
  return $self if($self);
  $self = bless {
    'Apache::Request' => $r,
  }, $class;
  $r->pnotes(__PACKAGE__, $self);
  return $self;
}

sub DESTROY { }

=for private_developer_docs

=head2 $mungo->cleanse();

Releases resources at the end of a request.

=cut

sub cleanse {
  my $self = shift;
  $self->Response()->cleanse();
  $self->Request()->cleanse();
  delete $self->{'Apache::Request'};
}

# Axiomatic "I am myself"
sub Server { return $_[0]; }
sub Request { return Mungo::Request->new($_[0]); }
sub Response { return Mungo::Response->new($_[0]); }

=head2 $encoded = $mungo->URLEncode($string);

=head2 $encoded = Mungo->URLEncode($string);

Encodes a string to escape characters that are not permitted in a URL.

=cut

sub URLEncode {
  my $self = shift;
  my $s = shift;
  $s =~ s/([^a-zA-Z0-9])/sprintf("%%%02x", ord($1))/eg;
  return $s;
}

=head2 $string = $mungo->URLDecode($encoded);

=head2 $string = Mungo->URLDecode($encoded);

Decodes a string to unescape characters that are not permitted in a URL.

=cut

sub URLDecode {
  my $self = shift;
  my $s = shift;
  $s =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/eg;
  return $s;
}
sub HTMLEncode {
  my $self = shift;
  my $s = shift;
  return HTML::Entities::encode_entities( $s );
}
sub HTMLDecode {
  my $self = shift;
  my $s = shift;
  return HTML::Entities::decode_entities( $s );
}

sub CurrentFile {
    my $self = shift;
    my @file_stack;

    # Unwind the stack.  Each time we hit a package whose name
    # begins with Mungo::FilePage, demangle the name and push onto our list.
    my $frame_count = 0;
    while (my @frame = caller($frame_count)) {
        $frame_count++;
        my $package = $frame[0];
        if ($package =~ /Mungo::(File|Mem)Page/) {
            my $awkwardly_built_string = $self->demangle_name($package . '::__content');
            $awkwardly_built_string =~ s{Mungo::(File|Mem)Page\((.+)\)}{$2};
            push @file_stack, $awkwardly_built_string;
        }
    }
    #print STDERR "have file_stack:\n" . Dumper(\@file_stack);

    return wantarray() ? @file_stack : $file_stack[0];
}

# Private?
sub demangle_name {
  my $self = shift;
  my $name = shift;
  if($name =~ /Mungo::FilePage::([^:]+)::__content/) {
    my $filename = decode_base64($1);
    my $r = $self->{'Apache::Request'};
    if(UNIVERSAL::can($r, 'document_root')) {
      my $base = $r->document_root();
      $filename =~ s/^$base//;
    }
    $name = "Mungo::FilePage($filename)";
  }
  elsif($name =~ /Mungo::MemPage::([^:]+)::__content/) {
    $name = 'Mungo::MemPage(ANON)';
  }
  return $name;
}

# Private?
sub filename2packagename {
  my ($self, $filename) = @_;
  my $type = ref $self;
  $type =~ s/::(?:File|Mem)Page::[^:]+$//;
  my $pkg = $type . "::FilePage::" . encode_base64($filename);
  $pkg =~ s/(\s|=*$)//gs;
  return $pkg;
}
sub contents2packagename {
  my($self, $contents) = @_;
  my $type = ref $self;
  $type =~ s/::(?:File|Mem)Page::[^:]+$//;
  return $type . "::MemPage::" . md5_hex( encode_utf8($$contents) );
}


# $output = $mungo->include_mem( 
#
sub include_mem {
  my $self = shift;
  my $contents = shift;
  my $pkg = $self->contents2packagename($contents);

  unless(UNIVERSAL::can($pkg, 'content')) {
    return unless $self->packagize($pkg, $contents);
    # The packagize was successful, make content do __content
    eval "*".$pkg."::content = \\&".$pkg."::__content;";
  }
  my %copy = %$self;
  my $page = bless \%copy, $pkg;
  $page->content(@_);
}
# Private?
sub include_file {
  my $self = shift;
  my $filename = shift;
  if($filename !~ /^\//) {
    my $dir = $self->{'Apache::Request'}->filename;
    $dir =~ s/[^\/]+$//;
    $filename = "$dir$filename";
  }
  my $pkg = $self->filename2packagename($filename);
  my ($inode, $mtime);
  if($self->{'Apache::Request'}->dir_config('StatINC')) {
    ($inode, $mtime) = (stat($filename))[1,9];
  }
  unless(UNIVERSAL::can($pkg, 'content') &&
         $inode == eval "\$${pkg}::Mungo_inode" &&
         $mtime == eval "\$${pkg}::Mungo_mtime") {
    open(my $fh, "<:encoding(UTF-8)", $filename)
        or die "$!: $filename";
    my $contents = do {
        local($/);
        <$fh>
    };
    close $fh;
    return unless $self->packagize($pkg, \$contents, $filename);
    # The packagize was successful, make content do __content
    eval "*${pkg}::content = \\&${pkg}::__content";
    # Track what we just compiled
    eval "\$${pkg}::Mungo_inode = $inode";
    eval "\$${pkg}::Mungo_mtime = $mtime";
  }
  my %copy = %$self;
  my $page = bless \%copy, $pkg;
  $page->content(@_);
}
# Private?
sub packagize {
  my $self = shift;
  my $pkg = shift;
  my $contents = shift;
  my $filename_hint = shift || '(unknown location)';
  my $expr = convertStringToExpression($contents);
  my $type = ref $self;
  $type =~ s/::(?:File|Mem)Page::[^:]+$//;

  # We build a package with a __content method.  Why?
  # If this fails miserably, there is still a possibility that
  # UNIVERSAL::can($pkg, 'content') will be true, so we make __content
  # and if it all works out, we *$pkg::content = \&$pkg::__content

  my $preamble = "package $pkg;" . q^
    use vars qw/@ISA $Mungo_inode $Mungo_mtime/;
    @ISA = qw/^. $type . q^/;
    sub __content {
      my $self = shift;
      my $Request = $self->Request();
      my $Response = $self->Response();
      my $Server = $self->Server();
#line 1 ^.$filename_hint.q^
^;
  my $postamble = q^
    }
    1;
    ^;

  # Set these before we attempt to compile so that if there is an error,
  # we can get access to the code from somewhere else.
  eval "\$${pkg}::Mungo_preamble = \$preamble;";
  eval "\$${pkg}::Mungo_postamble = \$postamble;";
  eval "\$${pkg}::Mungo_contents = \$contents;";

  open(my $fh, ">:encoding(UTF-8)", ">/tmp/wibble");
  print $fh "$preamble$expr$postamble";
  close $fh;

  eval $preamble . $expr . $postamble;
  if($@) {
    my $error = $@;
    if(ref $error ne 'HASH') {
      my $i = 0;
      my @callstack;
      while(my @callinfo = caller($i++)) {
        push @callstack, \@callinfo;
      }
      $error = { error => $error, callstack => \@callstack };
    }
    my ($line) = ($error->{error} =~ /line (\d+)/m);
    unshift @{$error->{callstack}},
      [
        $pkg, $filename_hint, $line, '(ASP include)'
      ];
    local $SIG{__DIE__} = undef;
    die $error;
  }
  return 1;
}


sub convertStringToExpression {
  my $string_ref = shift;
  my $string = $$string_ref;
  sub __string_as_i18n {
    return '' unless(length($_[0]));
    my $s = Data::Dumper->new([$_[0]])->Indent(0)->Dump;
    substr($s, 0, 7) = '<%= $main::Response->i18n(';
    substr($s, -1, 1) = ') %>';
    return $s;
  }
  sub __string_as_print {
    return '' unless(length($_[0]));
    my $s = Data::Dumper->new([$_[0]])->Indent(0)->Dump;
    substr($s, 0, 7) = 'print';
    return $s;
  }
  $string =~ s/I\[\[(.*?)\]\]/__string_as_i18n($1)/seg;
  $string =~ s/^(.*?)(?=<%|$)/__string_as_print($1)/se;
  # Replace non-code
  $string =~ s/(?<=%>)(?!<%)(.*?)(?=<%|$)/__string_as_print($1)/seg;
  # fixup code
  $string =~ s/
                <%([~=]?)(.*?)%>
              /
              ($1 eq '~') ? "print HTML::Entities::encode_entities($2,'<&>\"');" :
                ($1 eq '=') ? 
                  "print '',$2;" :        # This is <%= ... %>
                  "$2;"                   # This is <% ... %>
              /sexg;
  return $string;
}

=head1 LIMITATIONS/BUGS

=over 4

=item *

Cannot define subroutines in ASP pages.  Bad things will happen.

=item *

Documentation is spotty.  This is being worked on.

=back

=head1 LICENSE INFORMATION

Copyright (c) 2007 OmniTI Computer Consulting, Inc. All rights reserved.
For information on licensing see:

https://labs.omniti.com/mungo/trunk/LICENSE

=head1 PROJECT WEBSITE

https://labs.omniti.com/trac/mungo/

=head1 AUTHOR

Theo Schlossnagle (code)

Clinton Wolfe (docs)

=cut


1;
