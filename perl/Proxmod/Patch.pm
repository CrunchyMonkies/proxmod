package Proxmod::Patch;

use strict;
use warnings;

use Proxmod::Log qw(log_debug log_info log_warn log_error);

use JSON::PP ();
use Digest::SHA ();
use File::Path ();
use File::Basename ();

our $VERSION = '0.2.2';

# The managed patch facility — proxmod's escape hatch, and the part of it you
# should hope never to need.
#
# Everything else proxmod does happens at runtime, in memory, in directories
# Proxmox does not own. Nothing has to be reapplied after an upgrade because
# nothing was ever applied to a Proxmox file. That property is the project's
# entire argument, and this module gives it up: a patch edits a file that
# belongs to another package, and from that moment on every pve-manager upgrade
# is an event this host has to survive rather than one it can ignore.
#
# It exists anyway because the alternative is worse. Without a supported
# facility, the answer to "PVE has no seam here" is a shell script with sed in
# it and an /etc/apt/apt.conf.d hook, which is precisely what
# ~/dev/pmxxpuiov did — and which produced, in one small package, four
# defects that this module is shaped around:
#
#   1. Its reapply script patched a file its postinst did not, so the backend
#      route was silently never reapplied after an upgrade. Here, one engine
#      applies and reapplies from one spec: there is no second implementation
#      to drift.  -> converge()
#   2. backup_if_needed() skipped taking a backup when one already existed, so
#      after an upgrade the backup held the *pre-upgrade* file. Reverting then
#      restored an old Proxmox file over a new one. Here, apply() always
#      re-takes the backup, and revert() refuses to restore a backup whose
#      recorded hash does not match what is on disk now.  -> revert()
#   3. postrm left the backup behind forever, in a Proxmox-owned directory.
#      Here backups never live next to the file they came from; they live in
#      /var/lib/proxmod/backups, which only proxmod writes to and which purge
#      can therefore clear without ever touching another package's file.
#   4. Two such packages both editing index.html.tpl would race. Here every
#      edit is delimited by a marker naming the patch id, so two patches to one
#      file are independent and each can be removed without disturbing the
#      other.
#
# SHIPPED INERT. Every spec in the package has "enabled": 0. Installing proxmod
# patches nothing. Someone has to write a spec, or copy an example and flip a
# field, and the documentation is deliberately unenthusiastic about it.
#
# WHERE THIS RUNS. Not in a daemon. Nothing in Proxmod::Boot loads this module;
# pvedaemon starting up is the worst imaginable moment to rewrite a file that
# another process may be reading. It runs from /usr/lib/proxmod/proxmod-patch,
# which proxmod-reapply calls after it has finished converging its drop-ins,
# and which proxmodctl exposes.

# Spec drop-ins, same two-directory overlay as the extension registry: packaged
# specs under /usr/share, the administrator's under /etc, later wins by
# basename.
our @SPEC_DIRS = (
    '/usr/share/proxmod/patches',
    '/etc/proxmod/patches',
);

# Where a patched file is allowed to live. This is an allowlist and not a
# denylist on purpose: the set of directories it is ever reasonable to patch is
# small and known, while the set of files that must never be touched is
# unbounded and includes things nobody would think to enumerate.
our @PATCH_ROOTS = (
    '/usr/share/pve-manager',
    '/usr/share/perl5/PVE',
    '/usr/share/javascript/proxmox-widget-toolkit',
);

# /etc/pve is pmxcfs, a FUSE filesystem backed by a replicated database. It is
# unmounted during parts of an upgrade, its contents are cluster state rather
# than program code, and writing to it from a maintainer script is how you
# corrupt a cluster. It is not under any allowed root above; this list exists so
# that a future edit widening @PATCH_ROOTS still cannot reach it.
our @NEVER = ('/etc/pve');

our $STATE_FILE = '/var/lib/proxmod/patches.state';
our $BACKUP_DIR = '/var/lib/proxmod/backups';

# The uid a patchable file must belong to. Overridable only so the unit tests
# can run as a normal user; production never changes it. The group/world-write
# check below is not overridable, because that is the one that catches a real
# host being unsafe.
our $OWNER_UID = 0;

my $RE_ID = qr/\A([a-z0-9][a-z0-9_-]{0,63})\z/;

# Comment syntax for the delimiters, chosen from the target's extension unless
# the spec says otherwise. Getting this wrong does not corrupt the file in a
# subtle way — it breaks it outright the next time the daemon parses it — so it
# is worth not guessing: an unknown extension is a rejected spec, not a default.
my %COMMENT = (
    js   => [ '/* ', ' */' ],
    perl => [ '# ',  ''     ],
    html => [ '<!-- ', ' -->' ],
    css  => [ '/* ', ' */' ],
);

my %STYLE_BY_EXT = (
    js   => 'js',
    pm   => 'perl',
    pl   => 'perl',
    tpl  => 'html',
    html => 'html',
    htm  => 'html',
    css  => 'css',
);

sub _open_marker  { my ($s, $id) = @_; return $COMMENT{$s}[0] . "proxmod:begin $id" . $COMMENT{$s}[1] }
sub _close_marker { my ($s, $id) = @_; return $COMMENT{$s}[0] . "proxmod:end $id"   . $COMMENT{$s}[1] }

# Matches the whole delimited block including both marker lines. Anchored to
# line starts with /m so a marker mentioned inside a string somewhere else in
# the file cannot open a block.
sub _block_re {
    my ($id) = @_;
    return qr/^[^\n]*\Qproxmod:begin $id\E[^\n]*\n[\s\S]*?^[^\n]*\Qproxmod:end $id\E[^\n]*\n?/m;
}

sub _read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    binmode($fh);
    local $/;
    my $content = <$fh>;
    close($fh);
    return defined($content) ? $content : '';
}

# Write-then-rename, in the target's own directory so the rename is atomic. A
# reader that opens the file at any point during this sees either the whole old
# content or the whole new content — which matters, because the readers here
# are pveproxy handing the file to a browser and perl compiling a module.
sub _write_file_atomic {
    my ($path, $content, $mode) = @_;

    my $tmp = "$path.proxmod-tmp.$$";
    open(my $fh, '>', $tmp) or do {
        log_error("cannot write $tmp: $!");
        return 0;
    };
    binmode($fh);
    my $ok = print {$fh} $content;
    $ok &&= close($fh);
    if (!$ok) {
        log_error("cannot write $tmp: $!");
        unlink($tmp);
        return 0;
    }
    chmod($mode, $tmp) if defined $mode;
    if (!rename($tmp, $path)) {
        log_error("cannot rename $tmp to $path: $!");
        unlink($tmp);
        return 0;
    }
    return 1;
}

sub _sha256 {
    my ($content) = @_;
    return Digest::SHA::sha256_hex($content);
}

# --------------------------------------------------------------------------
# specs
# --------------------------------------------------------------------------

sub _parse_spec {
    my ($path, $basename) = @_;

    my $text = _read_file($path);
    if (!defined $text) {
        log_warn("patch spec unreadable, ignoring: $path: $!");
        return undef;
    }
    return { masked => 1, basename => $basename, source => $path } if $text !~ /\S/;

    my $raw;
    my $ok = eval { $raw = JSON::PP->new->utf8->relaxed->decode($text); 1 };
    if (!$ok || ref($raw) ne 'HASH') {
        my $err = $ok ? 'top level is not a JSON object' : ($@ || 'parse failed');
        $err =~ s/\s+$//;
        log_warn("patch spec invalid, ignoring: $path: $err");
        return undef;
    }

    my ($id) = (($raw->{id} // '') =~ $RE_ID);
    if (!defined $id) {
        log_warn("patch spec invalid, ignoring: $path: bad or missing 'id'");
        return undef;
    }

    my $spec = {
        id          => $id,
        source      => $path,
        basename    => $basename,
        description => ($raw->{description} // ''),
        # Absent means disabled. Every other part of proxmod defaults to
        # enabled; this one does not, because a spec that quietly starts
        # patching a Proxmox file because a field was left out is not a
        # mistake anyone should be able to make by omission.
        enabled     => (exists($raw->{enabled}) && $raw->{enabled}) ? 1 : 0,
        position    => ($raw->{position} // 'after'),
    };

    for my $field (qw(target anchor text)) {
        my $v = $raw->{$field};
        if (!defined($v) || ref($v) || !length("$v")) {
            log_warn("$id: bad or missing '$field', ignoring spec: $path");
            return undef;
        }
        $spec->{$field} = "$v";
    }

    # Before anything else about the spec is considered. This is the check with
    # teeth, and a spec that names a file proxmod must not touch should be
    # rejected for that reason and not for whichever cosmetic problem the
    # validation happened to reach first.
    if (my $why = _target_refused($spec->{target})) {
        log_warn("$id: refusing to patch $spec->{target}: $why");
        return undef;
    }

    if ($spec->{position} !~ /\A(?:after|before|replace)\z/) {
        log_warn("$id: 'position' must be after, before or replace, ignoring spec: $path");
        return undef;
    }

    my $style = $raw->{comment};
    if (!defined $style) {
        my ($ext) = ($spec->{target} =~ /\.([A-Za-z0-9]+)\z/);
        $style = defined($ext) ? $STYLE_BY_EXT{ lc $ext } : undef;
    }
    if (!defined($style) || !$COMMENT{$style}) {
        log_warn("$id: cannot tell what a comment looks like in $spec->{target};"
            . " set 'comment' to one of " . join(', ', sort keys %COMMENT)
            . ", ignoring spec: $path");
        return undef;
    }
    $spec->{comment} = $style;

    return $spec;
}

# Why this path may not be patched, or undef if it may. Split out from the rest
# of the validation because it is the check with teeth: everything else here
# protects the administrator from a typo, and this protects the host from a
# spec that was written to do harm.
sub _target_refused {
    my ($target) = @_;

    return 'not an absolute path'              if $target !~ m{\A/};
    return "contains '..'"                     if $target =~ m{(?:\A|/)\.\.(?:/|\z)};
    return 'contains a newline'                if $target =~ /\n/;

    for my $never (@NEVER) {
        return "$never is the cluster filesystem, not program code"
            if $target eq $never || index($target, "$never/") == 0;
    }

    for my $root (@PATCH_ROOTS) {
        return undef if index($target, "$root/") == 0;
    }
    return 'outside every directory proxmod is allowed to patch ('
        . join(', ', @PATCH_ROOTS) . ')';
}

sub _scan_spec_dir {
    my ($dir, $by_basename) = @_;

    opendir(my $dh, $dir) or do {
        log_debug("no patch spec directory at $dir");
        return;
    };
    my @names = sort grep { /\.conf\z/ && !/\A\./ } readdir($dh);
    closedir($dh);

    for my $name (@names) {
        my $path = "$dir/$name";
        next if !-f $path && !-l $path;
        my $spec;
        my $ok = eval { $spec = _parse_spec($path, $name); 1 };
        if (!$ok) {
            my $err = $@ || 'unknown error';
            $err =~ s/\s+$//;
            log_warn("patch spec threw while parsing, ignoring: $path: $err");
            next;
        }
        $by_basename->{$name} = $spec if defined $spec;
    }
    return;
}

# All specs the host has, valid or masked filtered out, in id order. Disabled
# specs are included: the caller needs to see them to report status, and
# converge() needs them to notice that something it applied is no longer wanted.
sub load_specs {
    my (%opt) = @_;
    my $dirs = $opt{dirs} || \@SPEC_DIRS;

    my %by_basename;
    _scan_spec_dir($_, \%by_basename) for @$dirs;

    my (@specs, %seen);
    for my $name (sort keys %by_basename) {
        my $s = $by_basename{$name};
        next if $s->{masked};
        if (my $prev = $seen{ $s->{id} }) {
            log_warn("duplicate patch id '$s->{id}': $s->{source} shadows"
                . " $prev->{source}, ignoring the later one");
            next;
        }
        $seen{ $s->{id} } = $s;
        push @specs, $s;
    }
    return [ sort { $a->{id} cmp $b->{id} } @specs ];
}

# --------------------------------------------------------------------------
# state
# --------------------------------------------------------------------------

sub read_state {
    my $text = _read_file($STATE_FILE);
    return { version => 1, patches => {} } if !defined($text) || $text !~ /\S/;

    my $raw;
    my $ok = eval { $raw = JSON::PP->new->utf8->decode($text); 1 };
    if (!$ok || ref($raw) ne 'HASH' || ref($raw->{patches}) ne 'HASH') {
        # Not fatal, but not silent either. An unreadable state file means
        # revert() cannot know what it did, so a human has to look: the patched
        # files still carry their markers and can be unpatched by hand.
        log_error("patch state at $STATE_FILE is unreadable; proxmod no longer"
            . " knows which patches it applied. Patched files still carry"
            . " proxmod:begin/end markers.");
        return { version => 1, patches => {}, broken => 1 };
    }
    return { version => 1, patches => $raw->{patches} };
}

# The one question every writer has to ask first. read_state() hands back an
# empty record set when it could not parse the file, and an empty record set is
# indistinguishable from a stock host — so a caller that just carried on would
# write a state file containing only whatever it did this run, discarding the
# backup path and orig_sha256 of every patch already applied. revert() could
# then neither restore those files nor clean up after them: defects 2 and 3
# from the header, reintroduced by the module that exists to prevent them.
#
# So nothing writes over a state file it could not read. The patched files
# still carry their proxmod:begin/end markers and can be unpatched by hand, and
# the backups are still in $BACKUP_DIR, named after the ids they belong to.
sub state_unusable {
    my ($state) = @_;
    return undef if !$state->{broken};
    return "patch state at $STATE_FILE is unreadable, so proxmod does not know"
        . " which patches it has already applied; refusing to patch or revert,"
        . " because recording this run would discard those records. Repair or"
        . " move aside $STATE_FILE first — the patched files still carry"
        . " proxmod:begin/end markers and $BACKUP_DIR still holds the backups.";
}

sub write_state {
    my ($state) = @_;

    # Belt and braces: every caller checks state_unusable() before it starts,
    # but this is the line that would do the damage.
    if (my $why = state_unusable($state)) {
        log_error($why);
        return 0;
    }

    File::Path::make_path(File::Basename::dirname($STATE_FILE));
    my $json = JSON::PP->new->utf8->canonical->pretty
        ->encode({ version => 1, patches => $state->{patches} });
    return _write_file_atomic($STATE_FILE, $json, 0600);
}

sub _backup_path {
    my ($id) = @_;
    # $id is already constrained to [a-z0-9_-], so this cannot escape the
    # directory however the spec was written.
    return "$BACKUP_DIR/$id.bak";
}

# --------------------------------------------------------------------------
# apply / revert
# --------------------------------------------------------------------------

# Everything a patch needs to know about the file it is about to edit, or an
# 'error' explaining why it is not going to.
sub _inspect_target {
    my ($spec) = @_;

    my $target = $spec->{target};

    if (my $why = _target_refused($target)) {
        return { error => "refusing to patch $target: $why" };
    }
    if (-l $target) {
        # A symlink's destination is not covered by the allowlist check above,
        # so following one would be a way around it.
        return { error => "$target is a symlink; proxmod patches plain files only" };
    }
    if (!-f $target) {
        return { error => "$target does not exist" };
    }

    my @st = stat($target);
    if (!@st) {
        return { error => "cannot stat $target: $!" };
    }
    my ($mode, $uid) = ($st[2], $st[4]);
    if ($uid != $OWNER_UID) {
        return { error => sprintf('%s is owned by uid %d, not %d', $target, $uid, $OWNER_UID) };
    }
    if ($mode & 022) {
        # A file pvedaemon compiles as root, that a non-root user can rewrite,
        # is a root escalation with or without proxmod. Patching it would make
        # proxmod complicit rather than merely present.
        return { error => sprintf('%s is group- or world-writable (mode %04o)', $target, $mode & 07777) };
    }

    my $content = _read_file($target);
    return { error => "cannot read $target: $!" } if !defined $content;

    return { content => $content, mode => $mode & 07777 };
}

# Apply one spec. Idempotent: if the marker block is already in the file this
# does nothing and reports 'already'. Returns a hashref with 'status' of
# applied | already | skipped | error, and 'message'.
sub apply {
    my ($spec) = @_;

    my $id = $spec->{id};
    return { status => 'skipped', message => 'not enabled' } if !$spec->{enabled};

    # Checked before the target is touched, not just before the state is
    # written: a patched file with no record of the patch is worse than an
    # unpatched one.
    my $state = read_state();
    if (my $why = state_unusable($state)) {
        return { status => 'error', message => $why };
    }

    my $info = _inspect_target($spec);
    return { status => 'error', message => $info->{error} } if $info->{error};

    my $content = $info->{content};
    my $re = _block_re($id);
    if ($content =~ $re) {
        # Already ours. Refresh nothing: the file on disk is what we want, and
        # rewriting it would change its mtime for no reason on every apt run.
        return { status => 'already', message => "$spec->{target} already carries $id" };
    }

    my $anchor = $spec->{anchor};
    my $count = 0;
    my $pos = 0;
    while ((my $at = index($content, $anchor, $pos)) >= 0) {
        $count++;
        $pos = $at + 1;
        last if $count > 1;
    }
    if ($count == 0) {
        # The overwhelmingly likely cause is that a PVE upgrade rewrote the
        # file. This is the failure mode the whole facility is judged on, so it
        # says so rather than reporting a bare "not found".
        return { status => 'error', message => "anchor not found in $spec->{target}"
            . " — the file has almost certainly changed; the spec needs updating" };
    }
    if ($count > 1) {
        return { status => 'error', message => "anchor appears more than once in"
            . " $spec->{target}; proxmod will not guess which one was meant" };
    }

    my $orig_sha = _sha256($content);
    my $at = index($content, $anchor);

    my $block = _open_marker($spec->{comment}, $id) . "\n"
        . $spec->{text} . (($spec->{text} =~ /\n\z/) ? '' : "\n")
        . _close_marker($spec->{comment}, $id) . "\n";

    my $patched = $content;
    if ($spec->{position} eq 'after') {
        my $end = $at + length($anchor);
        my $sep = ($end > 0 && substr($patched, $end - 1, 1) eq "\n") ? '' : "\n";
        substr($patched, $end, 0) = $sep . $block;
    } elsif ($spec->{position} eq 'before') {
        my $sep = ($at == 0 || substr($patched, $at - 1, 1) eq "\n") ? '' : "\n";
        substr($patched, $at, 0) = $sep . $block;
    } else {
        substr($patched, $at, length($anchor)) = $block;
    }

    # The backup is taken now, from the file as it is now — never reused from a
    # previous apply. That single line is defect 2 above: pve-gpu-manager kept
    # the first backup it ever took, so after an upgrade its backup was a
    # pre-upgrade Proxmox file, and reverting downgraded the host.
    File::Path::make_path($BACKUP_DIR);
    my $backup = _backup_path($id);
    if (!_write_file_atomic($backup, $content, 0600)) {
        return { status => 'error', message => "cannot write backup $backup; not patching" };
    }

    if (!_write_file_atomic($spec->{target}, $patched, $info->{mode})) {
        return { status => 'error', message => "cannot write $spec->{target}" };
    }

    $state->{patches}{$id} = {
        target         => $spec->{target},
        spec_source    => $spec->{source},
        backup         => $backup,
        orig_sha256    => $orig_sha,
        patched_sha256 => _sha256($patched),
        comment        => $spec->{comment},
        position       => $spec->{position},
        anchor         => $spec->{anchor},
    };
    write_state($state);

    log_info("patched $spec->{target} ($id)");
    return { status => 'applied', message => "patched $spec->{target}" };
}

# Undo one patch, by id, using only what the state file recorded. Returns a
# hashref with 'status' of reverted | unpatched | absent | error.
#
# This is the method the prior art got wrong, and the rule it gets right is:
#
#   restore the backup only if the file on disk is byte-for-byte what we wrote.
#
# If it is not, something else has written to that file since — in practice a
# pve-manager upgrade — and the backup is a snapshot of the *old* Proxmox file.
# Restoring it would silently downgrade a Proxmox component, which is a far
# worse outcome than leaving a stray comment behind. So instead we remove our
# own delimited block and leave everything else exactly as we found it.
sub revert {
    my ($id) = @_;

    my $state = read_state();
    if (my $why = state_unusable($state)) {
        return { status => 'error', message => $why };
    }
    my $entry = $state->{patches}{$id};
    return { status => 'absent', message => "no record of $id" } if !$entry;

    my $target = $entry->{target};
    my $result;

    if (!-f $target) {
        $result = { status => 'unpatched',
            message => "$target no longer exists; dropping the record for $id" };
    } elsif (-l $target) {
        return { status => 'error',
            message => "$target is now a symlink; refusing to touch it" };
    } else {
        my $content = _read_file($target);
        if (!defined $content) {
            return { status => 'error', message => "cannot read $target: $!" };
        }

        my $mine = (_sha256($content) eq ($entry->{patched_sha256} // ''));
        my $backup = $entry->{backup};
        my $orig = defined($backup) ? _read_file($backup) : undef;
        my $backup_ok = defined($orig)
            && _sha256($orig) eq ($entry->{orig_sha256} // '');

        my @st = stat($target);
        my $mode = @st ? ($st[2] & 07777) : undef;

        if ($mine && $backup_ok) {
            return { status => 'error', message => "cannot restore $target" }
                if !_write_file_atomic($target, $orig, $mode);
            $result = { status => 'reverted', message => "restored $target from backup" };

        } elsif ($content =~ _block_re($id)) {
            my $why = !$mine
                ? "$target has changed since proxmod patched it"
                : "the backup for $id is missing or does not match what was recorded";
            my $out = $content;
            # A 'replace' patch consumed the anchor, so putting the block back
            # means putting the anchor back; the other positions left it alone
            # and only the block has to go.
            my $replacement = ($entry->{position} // '') eq 'replace'
                ? ($entry->{anchor} // '') : '';
            my $block_re = _block_re($id);
            $out =~ s/$block_re/$replacement/;
            return { status => 'error', message => "cannot rewrite $target" }
                if !_write_file_atomic($target, $out, $mode);
            log_warn("$why; removed proxmod's own block from $target instead of"
                . " restoring the backup, which would have reinstated an older file");
            $result = { status => 'unpatched', message => "removed the $id block from $target" };

        } else {
            $result = { status => 'unpatched',
                message => "$target no longer carries $id; nothing to undo" };
        }
    }

    # The backup goes with the record. Leaving either behind is defect 3: a
    # file nobody owns, that no later version of proxmod will look for, sitting
    # on the host until someone notices it.
    unlink($entry->{backup}) if defined $entry->{backup};
    delete $state->{patches}{$id};
    write_state($state);
    rmdir($BACKUP_DIR);

    log_info("reverted $id: $result->{message}");
    return $result;
}

# Make the host match the specs: apply everything enabled, undo everything we
# once applied that is no longer wanted. This is the only entry point anything
# automated calls — proxmod-reapply on a dpkg trigger, and proxmod-verify.service
# at boot — so it has to be safe to run at any time and cheap when there is
# nothing to do.
#
# On a stock install there are no enabled specs and no state, and this walks two
# directories, finds nothing, writes nothing and returns.
sub converge {
    my (%opt) = @_;

    my $specs = load_specs(%opt);
    my %by_id = map { $_->{id} => $_ } @$specs;

    my @results;
    my $failed = 0;

    my $state = read_state();
    if (my $why = state_unusable($state)) {
        log_error($why);
        return { results => [ { id => '-', status => 'error', message => $why } ],
            failed => 1 };
    }

    for my $id (sort keys %{ $state->{patches} }) {
        next if $by_id{$id} && $by_id{$id}{enabled};
        # Either the spec was disabled, or its file was removed — the packaged
        # spec deleted by an upgrade, say. Both mean the host should no longer
        # carry the edit.
        my $r = revert($id);
        $r->{id} = $id;
        push @results, $r;
        $failed++ if $r->{status} eq 'error';
    }

    for my $spec (@$specs) {
        next if !$spec->{enabled};
        my $r = apply($spec);
        $r->{id} = $spec->{id};
        push @results, $r;
        $failed++ if $r->{status} eq 'error';
    }

    return { results => \@results, failed => $failed };
}

# Undo everything, regardless of what the specs currently say. Called from the
# package's prerm on *remove* — and deliberately not on upgrade, because
# reverting during an upgrade is how the prior art restored a stale file over a
# newer one at the exact moment nobody was watching.
sub revert_all {
    my $state = read_state();
    if (my $why = state_unusable($state)) {
        log_error($why);
        return { results => [ { id => '-', status => 'error', message => $why } ],
            failed => 1 };
    }

    my @results;
    my $failed = 0;
    for my $id (sort keys %{ $state->{patches} }) {
        my $r = revert($id);
        $r->{id} = $id;
        push @results, $r;
        $failed++ if $r->{status} eq 'error';
    }
    return { results => \@results, failed => $failed };
}

# What this host looks like: every spec, whether it is enabled, and whether the
# file currently carries it. Reads only; safe for anyone to run.
sub status {
    my (%opt) = @_;

    my $specs = load_specs(%opt);
    my $state = read_state();
    my %seen;

    my @out;
    for my $spec (@$specs) {
        my $id = $spec->{id};
        $seen{$id} = 1;
        my $entry = $state->{patches}{$id};
        my $content = -f $spec->{target} ? _read_file($spec->{target}) : undef;
        my $present = defined($content) && $content =~ _block_re($id) ? 1 : 0;
        push @out, {
            id          => $id,
            description => $spec->{description},
            target      => $spec->{target},
            source      => $spec->{source},
            enabled     => $spec->{enabled},
            applied     => $present,
            recorded    => $entry ? 1 : 0,
            drifted     => ($entry && defined($content)
                && _sha256($content) ne ($entry->{patched_sha256} // '')) ? 1 : 0,
        };
    }

    # A record with no spec is not a bookkeeping error; it is a patch that is
    # still on the host with nothing left to describe it, which is exactly the
    # thing an administrator needs told.
    for my $id (sort keys %{ $state->{patches} }) {
        next if $seen{$id};
        push @out, {
            id       => $id,
            target   => $state->{patches}{$id}{target},
            enabled  => 0,
            applied  => 1,
            recorded => 1,
            orphaned => 1,
        };
    }

    return [ sort { $a->{id} cmp $b->{id} } @out ];
}

1;
