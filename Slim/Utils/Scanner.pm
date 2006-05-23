package Slim::Utils::Scanner;

# $Id$
#
# SlimServer Copyright (c) 2001-2005 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, version 2.

# This file implements a number of class methods to scan directories,
# playlists & remote "files" and add them to our data store.
#
# It is meant to be simple and straightforward. Short methods that do what
# they say and no more.

use strict;
use base qw(Class::Data::Inheritable);

use FileHandle;
use File::Basename qw(basename);
use File::Find::Rule;
use IO::String;
use Path::Class;
use Scalar::Util qw(blessed);

use Slim::Formats::Parse;
use Slim::Music::Info;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Misc;

sub init {
	my $class = shift;

        $class->mk_classdata('useProgressBar');

	$class->useProgressBar(0);

	# Term::ProgressBar requires Class::MethodMaker, which is rather large and is
	# compiled. Many platforms have it already though..
	eval "use Term::ProgressBar";

	if (!$@ && -t STDOUT) {

		$class->useProgressBar(1);
	}
}

sub scanProgressBar {
	my $class = shift;
	my $count = shift;

	if ($class->useProgressBar) {

		return Term::ProgressBar->new({
			'count' => $count,
			'ETA'   => 'linear',
		});
	}

	return undef;
}

# Scan a directory on disk, and depending on the type of file, add it to the database.
sub scanDirectory {
	my $class = shift;
	my $args  = shift;

	# Can't do much without a starting point.
	if (!$args->{'url'}) {
		return;
	}

	my $ds     = Slim::Music::Info::getCurrentDataStore();
	my $os     = Slim::Utils::OSDetect::OS();

	# Create a Path::Class::Dir object ofr later use.
	my $topDir = dir($args->{'url'});

	# See perldoc File::Find::Rule for more information.
	# follow symlinks.
	my $rule   = File::Find::Rule->new;
	my $extras = { 'no_chdir' => 1 };

	# File::Find doesn't like follow on Windows.
	if ($os ne 'win') {
		$extras->{'follow'} = 1;
	}

	$rule->extras($extras);

	# validTypeExtensions returns a qr// regex.
	$rule->name( Slim::Music::Info::validTypeExtensions() );

        my @files = $rule->in($topDir);

	if (!scalar @files) {

		$::d_scan && msg("scanDirectory: Didn't find any valid files in: [$topDir]\n");
		return;
	}

	# Give the user a progress indicator if available.
	my $progress = $class->scanProgressBar(scalar @files);

        for my $file (@files) {

		my $url = Slim::Utils::Misc::fileURLFromPath($file);

		# Only check for Windows Shortcuts on Windows.
		# Are they named anything other than .lnk? I don't think so.
		if ($file =~ /\.lnk$/) {

			if ($os ne 'win') {
				next;
			}

			$url  = Slim::Utils::Misc::fileURLFromWinShortcut($url) || next;
			$file = Slim::Utils::Misc::pathFromFileURL($url);

			# Bug: 2485:
			# Use Path::Class to determine if the file points to a
			# directory above us - if so, that's a loop and we need to break it.
			if (dir($file)->subsumes($topDir)) {

				errorMsg("Found an infinite loop! Breaking out: $file -> $topDir\n");
				next;
			}

			# Recurse
			if (Slim::Music::Info::isDir($url) || Slim::Music::Info::isWinShortcut($url)) {

				$::d_scan && msg("scanDirectory: Following Windows Shortcut to: $url\n");

				$class->scanDirectory({ 'url' => $file });
				next;
			}
		}

		# If we have an audio file or a CUE sheet (in the music dir), scan it.
		if (Slim::Music::Info::isSong($url) || Slim::Music::Info::isCUE($url)) {

			$::d_scan && msg("ScanDirectory: Adding $url to database.\n");

			$ds->updateOrCreate({
				'url'      => $url,
				'readTags' => 1,
			});
		}

		# Only read playlist files if we're in the playlist dir, and
		# it's not a CUE, which we've scanned above.
		if (Slim::Music::Info::isPlaylist($url) && 
		    Slim::Utils::Misc::inPlaylistFolder($url) && 
		    !Slim::Music::Info::isCUE($url) &&
		    $url !~ /ShoutcastBrowser_Recently_Played/) {

			$::d_scan && msg("ScanDirectory: Adding playlist $url to database.\n");

			my $track = $ds->updateOrCreate({
				'url'      => $url,
				'readTags' => 0,
			});

			$class->scanPlaylistFileHandle($track, FileHandle->new($file));
		}

		if ($class->useProgressBar) {

			$progress->update;
		}
	}
}

sub scanRemoteURL {
	my $class = shift;
	my $args  = shift;

	my $url   = $args->{'url'} || return;
	my $ds    = Slim::Music::Info::getCurrentDataStore();

	if (!Slim::Music::Info::isRemoteURL($url)) {

		return 0;
	}

	$::d_scan && msg("scanRemoteURL: opening remote stream $url\n");

	my $remoteFH = Slim::Player::ProtocolHandlers->openRemoteStream($url);

	if (!$remoteFH) {
		errorMsg("scanRemoteURL: Can't connect to remote server to retrieve playlist.\n");
		return 0;
	}

	#
	my $track = $ds->updateOrCreate({
		'url'      => $url,
		'readTags' => 0,
	});

	# Check if it's still a playlist after we open the
	# remote stream. We may have got a different content
	# type while loading.
	if (Slim::Music::Info::isSong($track)) {

		$::d_scan && msg("scanRemoteURL: found that $url is audio!\n");

		if (defined $remoteFH) {

			$remoteFH->close;
			$remoteFH = undef;

			return 0;
		}
	}

	return $class->scanPlaylistFileHandle($track, $remoteFH);
}

sub scanPlaylistFileHandle {
	my $class      = shift;
	my $track      = shift;
	my $playlistFH = shift || return;

	my $parentDir  = undef;
	my $ds         = Slim::Music::Info::getCurrentDataStore();

	if (Slim::Music::Info::isFileURL($track)) {

		#XXX This was removed before in 3427, but it really works best this way
		#XXX There is another method that comes close if this shouldn't be used.
		$parentDir = Slim::Utils::Misc::fileURLFromPath( file($track->path)->parent );

		$::d_scan && msg("scanPlaylistFileHandle: will scan $track, base: $parentDir\n");
	}

	if (ref($playlistFH) eq 'Slim::Player::Protocols::HTTP') {

		# we've just opened a remote playlist.  Due to the synchronous
		# nature of our parsing code and our http socket code, we have
		# to make sure we download the entire file right now, before
		# parsing.  To do that, we use the content() method.  Then we
		# convert the resulting string into the stream expected by the parsers.
		my $playlistString = $playlistFH->content;

		# Be sure to close the socket before reusing the
		# scalar - otherwise we'll leave the socket in a CLOSE_WAIT state.
		$playlistFH->close;
		$playlistFH = undef;

		$playlistFH = IO::String->new($playlistString);
	}

	my @playlistTracks = Slim::Formats::Parse::parseList($track, $playlistFH, $parentDir);

	# Be sure to remove the reference to this handle.
	if (ref($playlistFH) eq 'IO::String') {
		untie $playlistFH;
	}

	undef $playlistFH;

	if (scalar @playlistTracks) {

		# Create a playlist container
		if (!$track->title) {

			my $title = Slim::Utils::Misc::unescape(basename($track->url));
			   $title =~ s/\.\w{3}$//;

			$track->title($title);
		}

		# With the special url if the playlist is in the
		# designated playlist folder. Otherwise, Dean wants
		# people to still be able to browse into playlists
		# from the Music Folder, but for those items not to
		# show up under Browse Playlists.
		#
		# Don't include the Shoutcast playlists or cuesheets
		# in our Browse Playlist view either.
		my $ct = $ds->contentType($track);

		if (Slim::Music::Info::isFileURL($track) && Slim::Utils::Misc::inPlaylistFolder($track) &&
			$track !~ /ShoutcastBrowser_Recently_Played/ && !Slim::Music::Info::isCUE($track)) {

			$ct = 'ssp';
		}

		$track->content_type($ct);
		$track->setTracks(\@playlistTracks);
		$track->update;
	}

	$::d_scan && msgf("scanPlaylistFileHandle: found %d items in playlist.\n", scalar @playlistTracks);

	return wantarray ? @playlistTracks : \@playlistTracks;
}

1;

__END__
