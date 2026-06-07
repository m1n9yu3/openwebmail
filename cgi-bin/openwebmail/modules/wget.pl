package ow::wget;
#
# wget.pl - fetch url with wget, then return the filehandle of fetched object
#
# 2005/01/10 tung.AT.turtle.ee.ncku.edu.tw
#
# This module requires the wget program to be passed as $wgetbin
# wget program is available at http://www.gnu.org/software/wget/wget.html,
#

use strict;
use warnings FATAL => 'all';

use Fcntl qw(:DEFAULT :flock);
use Socket;

require "modules/tool.pl";

sub get_handle {
   my ($wgetbin, $url)=@_;

   return(-2, 'URL host is not allowed') unless is_public_url($url);

   my ($outfh, $outfile)=ow::tool::mktmpfile('wget.tmpfile');
   my ($errfh, $errfile)=ow::tool::mktmpfile('wget.err');

   open(SAVEERR,">&STDERR"); open(STDERR,">&=".fileno($errfh)); close($errfh);
   open(SAVEOUT,">&STDOUT"); open(STDOUT,">&=".fileno($outfh)); close($outfh);
   select(STDERR); $|=1; select(STDOUT); $|=1;

   local $SIG{CHLD}; # disable $SIG{CHLD} temporarily for wait()

   system($wgetbin, "-l0", "--max-redirect=0", "-O-", ow::tool::untaint($url));

   open(STDERR,">&SAVEERR"); close(SAVEERR);
   open(STDOUT,">&SAVEOUT"); close(SAVEOUT);

   my $exit=$?>>8;
   if ( $exit!=0 && (-s $errfile)==0) {
      unlink($outfile, $errfile);
      return(-1, "fork error?");
   }

   my ($contenttype, $errmsg)=('', '');
   sysopen(ERR, $errfile, O_RDONLY);
   while (<ERR>) {
      $contenttype=$1 if (m!\d+ \[([a-z]+/[a-z\-]+)\]!);
      $errmsg=$_ if (/\S+/);
   }
   close(ERR);
   unlink($errfile);

   if ($exit!=0) {
      unlink($outfile);
      $errmsg=~s/^\d\d:\d\d:\d\d\s*//; $errmsg=~s/[\r\n]//g;
      return(-2, $errmsg);
   } else {
      my $handle=do { local *FH };
      sysopen($handle, $outfile, O_RDONLY);
      unlink($outfile);
      $contenttype=ow::tool::ext2contenttype($url) if ($contenttype eq '');
      return(0, '', $contenttype, $handle);
   }
}

sub is_public_url {
   my $url = shift || '';

   my ($scheme, $authority) = $url =~ m{^([A-Za-z][A-Za-z0-9+.-]*)://([^/\?#]*)};
   return 0 unless defined $scheme && defined $authority;
   return 0 unless $scheme =~ m/^(?:https?|ftp)$/i;

   $authority =~ s/^[^@]*@//;

   my $host = '';
   if ($authority =~ m/^\[([^\]]+)\](?::\d+)?$/) {
      return 0; # IPv6 validation is not implemented here; fail closed.
   } elsif ($authority =~ m/^([^:]+)(?::\d+)?$/) {
      $host = lc($1);
   } else {
      return 0;
   }

   return is_public_host($host);
}

sub is_public_host {
   my $host = shift || '';

   $host = lc($host);
   $host =~ s/\.$//;
   return 0 if $host eq '' || $host =~ m/[\s\000-\037]/;
   return 0 if $host eq 'localhost' || $host =~ m/\.localhost$/;
   return 0 if $host =~ m/:/; # IPv6 validation is not implemented here; fail closed.

   my @addrs = ();
   if (my $addr = inet_aton($host)) {
      push(@addrs, $addr);
   } else {
      my ($name, $aliases, $addrtype, $length, @resolved) = gethostbyname($host);
      @addrs = @resolved;
   }

   return 0 if scalar @addrs < 1;

   foreach my $addr (@addrs) {
      return 0 if !defined $addr || length($addr) != 4 || is_private_ipv4($addr);
   }

   return 1;
}

sub is_private_ipv4 {
   my $addr = shift;
   my ($a, $b, $c, $d) = unpack('C4', $addr);

   return 1 if $a == 0;
   return 1 if $a == 10;
   return 1 if $a == 100 && $b >= 64 && $b <= 127;
   return 1 if $a == 127;
   return 1 if $a == 169 && $b == 254;
   return 1 if $a == 172 && $b >= 16 && $b <= 31;
   return 1 if $a == 192 && $b == 168;
   return 1 if $a == 192 && $b == 0 && $c == 0;
   return 1 if $a == 192 && $b == 0 && $c == 2;
   return 1 if $a == 192 && $b == 88 && $c == 99;
   return 1 if $a == 198 && $b >= 18 && $b <= 19;
   return 1 if $a == 198 && $b == 51 && $c == 100;
   return 1 if $a == 203 && $b == 0 && $c == 113;
   return 1 if $a >= 224;

   return 0;
}

1;
