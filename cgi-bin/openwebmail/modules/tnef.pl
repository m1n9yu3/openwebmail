package ow::tnef;
#
# tnef.pl - tnef -> zip/tar/tgz transformation routine
#
# 2004/07/18 tung.AT.turtle.ee.ncku.edu.tw
#
# tnef (Transport Neutral Encapsulation Format) is used mostly by
# Microsoft Outlook and Exchange server
#
# This module requires the tnef program to be passed as $tnefbin
# tnef program is available at http://tnef.sourceforge.net/,
# it is written by Mark Simpson <verdammelt@users.sourceforge.net>
#

use strict;
use warnings FATAL => 'all';

use Fcntl qw(:DEFAULT :flock);

require "modules/tool.pl";
require "modules/suid.pl";

sub _safe_tnef_member_name {
   my ($name, $r_used) = @_;

   $name = '' unless defined $name;
   $name =~ s#\\#/#g;
   $name =~ s#^.*/##;
   $name =~ s#^.*:##;
   $name =~ s/[\x00-\x1F\x7F"\\]/_/g;
   $name =~ s/^\s+//;
   $name =~ s/\s+$//;
   $name =~ s/^\.+$//;
   $name =~ s/^-/_/;
   $name = 'attachment' if $name eq '';

   if (length($name) > 128) {
      my ($base, $ext) = $name =~ m/^(.{1,120}?)(\.[^.]*)?$/;
      $name = $base . (defined $ext ? substr($ext, 0, 8) : '');
   }

   my $candidate = $name;
   my $i = 1;
   while ($r_used->{$candidate}) {
      my ($base, $ext) = $name =~ m/^(.+?)(\.[^.]*)?$/;
      $candidate = $base . '-' . $i++ . (defined $ext ? $ext : '');
   }

   $r_used->{$candidate} = 1;
   return $candidate;
}

sub _copy_regular_file {
   my ($src, $dst) = @_;

   return 0 if -l $src || !-f $src;

   sysopen(my $in, $src, O_RDONLY) or return 0;
   sysopen(my $out, $dst, O_WRONLY|O_TRUNC|O_CREAT) or do {
      close($in);
      return 0;
   };

   binmode($in);
   binmode($out);

   my $buf = '';
   while (read($in, $buf, 32768)) {
      print $out $buf or do {
         close($in);
         close($out);
         return 0;
      };
   }

   close($in);
   close($out);
   return 1;
}

sub _stage_tnef_files {
   my $srcdir = shift;

   my $stagedir = ow::tool::mktmpdir('tnef.safe');
   return ('') if $stagedir eq '';

   my @dirs = ($srcdir);
   my %used = ();
   my @filelist = ();

   while (defined(my $dir = shift @dirs)) {
      opendir(my $dh, $dir) or next;
      while (defined(my $entry = readdir($dh))) {
         next if $entry eq '.' || $entry eq '..';

         my $src = "$dir/$entry";
         next if -l $src;

         if (-d $src) {
            push(@dirs, $src);
            next;
         }

         next unless -f $src;

         my $dstname = _safe_tnef_member_name($entry, \%used);
         if (_copy_regular_file($src, "$stagedir/$dstname")) {
            push(@filelist, $dstname);
         }
      }
      closedir($dh);
   }

   if (scalar @filelist == 0) {
      rmdir($stagedir);
      return ('');
   }

   return ($stagedir, @filelist);
}

sub get_tnef_filelist {
   my ($tnefbin, $r_tnef) = @_;

   local $SIG{CHLD}; # disable $SIG{CHLD} temporarily for wait()

   local $| = 1; # flush all output

   my ($outfh, $outfile) = ow::tool::mktmpfile('tnef.out');
   open(F, "|-") or
      do {
            open(STDERR,">/dev/null");
            open(STDOUT,">&=".fileno($outfh));
            exec($tnefbin, "-t", "--save-body=messagebody");
            exit 9;
         };
   close($outfh);
   print F ${$r_tnef};
   close(F);

   my @filelist=();
   sysopen(F, $outfile, O_RDONLY);
   unlink $outfile;
   while (<F>) {
     chomp;
     push(@filelist, $_) if ($_ ne '');
   }
   close(F);

   return(@filelist);
}

sub get_tnef_archive {
   my ($tnefbin, $tnefname, $r_tnef) = @_;
   my ($arcname, $arcdata);

   local $SIG{CHLD}; # disable $SIG{CHLD} temporarily for wait()

   local $| = 1; # flush all output

   # set umask so the dir/file created by tnefbin will be readable
   # by uid/gid other than current euid/egid
   # (eg: if the shell is bash and current ruid!=0, the following forked
   #      tar/gzip may have ruid=euid=current ruid,
   #      which is not the same as current euid)
   my $oldumask = umask(0000);
   my $tmpdir = ow::tool::mktmpdir('tnef.tmp');
   return('', \$arcdata) if ($tmpdir eq '');

   open(F, "|-") or
      do {
            open(STDERR,">/dev/null");
            open(STDOUT,">/dev/null");
            exec($tnefbin, "--overwrite", "--save-body=messagebody", "-C", $tmpdir);
            exit 9;
         };
   print F ${$r_tnef};
   close(F);
   umask($oldumask);

   my ($stagedir, @filelist) = _stage_tnef_files($tmpdir);

   my $rmbin = ow::tool::findbin('rm');
   system($rmbin, '-Rf', $tmpdir) if ($rmbin ne '');
   $tmpdir = $stagedir;

   if ($#filelist < 0) {
      rmdir($tmpdir) if $tmpdir ne '';
      return('', \$arcdata);
   } elsif ($#filelist == 0) {
      sysopen(F, "$tmpdir/$filelist[0]", O_RDONLY);
      $arcname = $filelist[0];
   } else {
      my ($zipbin, $tarbin, $gzipbin);
      $arcname = $tnefname;
      $arcname =~ s/\.[\w\d]{0,4}$//;
      if (($zipbin = ow::tool::findbin('zip')) ne '') {
         open(F, "-|") or
            do {
                  open(STDERR,">/dev/null");
                  exec($zipbin, "-ryqj", "-", $tmpdir);
                  exit 9;
               };
         $arcname .= ".zip";
      } elsif (($tarbin = ow::tool::findbin('tar')) ne '') {
         if (($gzipbin = ow::tool::findbin('gzip')) ne '') {
            open(F, "-|") or
               do {
                     open(STDERR,">/dev/null");
                     exec($tarbin, "-C", $tmpdir, "-zcf", "-", ".");
                     exit 9;
                  };
            $arcname .= ".tgz";
         } else {
            open(F, "-|") or
               do {
                     open(STDERR,">/dev/null");
                     exec($tarbin, "-C", $tmpdir, "-cf", "-", ".");
                     exit 9;
                  };
            $arcname .= ".tar";
         }
      } else {
         rmdir($tmpdir);
         return('', \$arcdata);
      }
   }
   local $/;
   undef $/;
   $arcdata = <F>;
   close(F);

   system($rmbin, '-Rf', $tmpdir) if ($rmbin ne '');
   return($arcname, \$arcdata, @filelist);
}

1;
