#!/usr/bin/perl -T

use strict;
use warnings;

use lib 't/lib';
use lib 'perl';

use Test::More;
use ProxmodTest qw(tempdir write_file capture_log is_tainted);

use Proxmod::Registry;

plan tests => 73;

# Two directories, mirroring the real layout: the package-owned drop-in
# directory and the administrator's override directory on top of it.
my $root  = tempdir();
my $pkg   = "$root/usr";
my $admin = "$root/etc";
mkdir $_ or die "mkdir: $!" for ($pkg, $admin);

sub load_from {
    my (@dirs) = @_;
    return capture_log(sub { Proxmod::Registry::load(dirs => \@dirs) });
}

sub ids { return [ map { $_->{id} } @{ $_[0] } ] }

sub clear {
    for my $dir ($pkg, $admin) {
        opendir(my $dh, $dir) or next;
        my @names = grep { !/\A\.\.?\z/ } readdir($dh);
        closedir($dh);
        # readdir is tainted and unlink refuses tainted arguments under -T.
        for my $name (@names) {
            next if $name !~ m{\A([\w.-]+)\z};
            unlink "$dir/$1";
        }
    }
    return;
}

sub manifest {
    my ($dir, $name, $json) = @_;
    return write_file("$dir/$name", $json);
}

sub manifest_json {
    my ($dir, $name, $data) = @_;
    require JSON::PP;
    return manifest($dir, $name, JSON::PP->new->encode($data));
}

# --- a minimal, valid manifest -------------------------------------------

manifest($pkg, '50-hello.conf', <<'JSON');
{
  "id": "hello",
  "version": "1.0.0",
  "backend":  { "module": "Acme::Hello" },
  "frontend": { "assets": ["hello.js"] }
}
JSON

{
    my ($exts, $log) = load_from($pkg, $admin);
    is(scalar(@$exts), 1, 'one extension loads');
    is($exts->[0]{id}, 'hello', 'id is read');
    is($exts->[0]{backend}{module}, 'Acme::Hello', 'backend module is read');
    is_deeply($exts->[0]{frontend}{assets}, ['hello.js'], 'frontend assets are read');
    is($exts->[0]{order}, 50, 'order defaults to 50');
    is($exts->[0]{enabled}, 1, 'enabled defaults to true');

    # Absent "daemons" means both, so an author who does not care about the
    # distinction gets the behaviour they expect.
    is_deeply([ sort keys %{ $exts->[0]{backend}{daemons} } ], ['pvedaemon', 'pveproxy'],
        'daemons defaults to both API daemons');

    is($log, '', 'a well-formed manifest logs nothing');
}

# --- taint ----------------------------------------------------------------

# This is the assertion the daemons depend on. The module name is about to be
# passed to require(), and require() of a tainted string dies — inside pvedaemon
# at startup, which means a host with no API.
{
    my ($exts) = load_from($pkg, $admin);
    ok(${^TAINT}, 'this test really is running under -T');
    ok(!is_tainted($exts->[0]{backend}{module}), 'backend module name is untainted');
    ok(!is_tainted($exts->[0]{id}), 'extension id is untainted');
    ok(!is_tainted($exts->[0]{frontend}{assets}[0]), 'asset filename is untainted');

    # And the control: a value read off disk that we have not deliberately
    # untainted is still tainted, proving the probe above can actually fail.
    ok(is_tainted($exts->[0]{version}), 'a field we did not untaint is still tainted');
}

# --- the administrator overlay -------------------------------------------

manifest($admin, '50-hello.conf', <<'JSON');
{
  "id": "hello",
  "backend": { "module": "Acme::HelloOverridden" }
}
JSON

{
    my ($exts) = load_from($pkg, $admin);
    is(scalar(@$exts), 1, 'an override replaces rather than adds');
    is($exts->[0]{backend}{module}, 'Acme::HelloOverridden', 'the /etc copy wins');
    ok(!$exts->[0]{frontend}, 'the override replaces the manifest outright, not field by field');
}

# An empty file under /etc masks a packaged extension. That survives the
# extension package being reinstalled, which editing the packaged file does not.
manifest($admin, '50-hello.conf', "\n");
{
    my ($exts, $log) = load_from($pkg, $admin);
    is(scalar(@$exts), 0, 'an empty override masks the extension');
    unlike($log, qr/warn/, 'masking is not a warning; it is a supported action');
}

clear();

# --- enabled: false -------------------------------------------------------

manifest($pkg, '50-off.conf', '{"id":"off","enabled":false,"backend":{"module":"Acme::Off"}}');
{
    my ($exts) = load_from($pkg, $admin);
    is(scalar(@$exts), 0, '"enabled": false keeps an extension out');
}

clear();

# --- ordering -------------------------------------------------------------

manifest($pkg, '90-late.conf',  '{"id":"late","order":90,"backend":{"module":"A::Late"}}');
manifest($pkg, '10-early.conf', '{"id":"early","order":10,"backend":{"module":"A::Early"}}');
manifest($pkg, '50-mid.conf',   '{"id":"mid","backend":{"module":"A::Mid"}}');
{
    my ($exts) = load_from($pkg, $admin);
    is_deeply(ids($exts), ['early', 'mid', 'late'], 'extensions load in "order" order');
}

# Equal order falls back to the filename, so the result never depends on the
# order readdir happens to return.
manifest($pkg, '50-aaa.conf', '{"id":"aaa","order":50,"backend":{"module":"A::Aaa"}}');
manifest($pkg, '50-zzz.conf', '{"id":"zzz","order":50,"backend":{"module":"A::Zzz"}}');
{
    my ($exts) = load_from($pkg, $admin);
    is_deeply(ids($exts), ['early', 'aaa', 'mid', 'zzz', 'late'],
        'equal order is broken by filename');
}

clear();

# --- requires -------------------------------------------------------------

manifest($pkg, '10-consumer.conf',
    '{"id":"consumer","order":10,"requires":["provider"],"backend":{"module":"A::Consumer"}}');
manifest($pkg, '90-provider.conf',
    '{"id":"provider","order":90,"backend":{"module":"A::Provider"}}');
{
    my ($exts) = load_from($pkg, $admin);
    is_deeply(ids($exts), ['provider', 'consumer'],
        '"requires" overrides the declared order');
}

clear();

manifest($pkg, '50-orphan.conf',
    '{"id":"orphan","requires":["nowhere"],"backend":{"module":"A::Orphan"}}');
manifest($pkg, '50-fine.conf', '{"id":"fine","backend":{"module":"A::Fine"}}');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is_deeply(ids($exts), ['fine'], 'an extension with an absent dependency is dropped');
    like($log, qr/orphan: not loading, requires missing extension\(s\): nowhere/,
        'and the reason names the missing dependency');
}

clear();

manifest($pkg, '50-a.conf', '{"id":"a","requires":["b"],"backend":{"module":"A::A"}}');
manifest($pkg, '50-b.conf', '{"id":"b","requires":["a"],"backend":{"module":"A::B"}}');
manifest($pkg, '50-c.conf', '{"id":"c","backend":{"module":"A::C"}}');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is_deeply(ids($exts), ['c'], 'a dependency cycle drops only its members');
    like($log, qr/dependency cycle/, 'and says so');
}

clear();

# --- malformed input ------------------------------------------------------

# The isolation property: one bad manifest costs exactly itself. On a live host
# this is the difference between one extension missing and the daemon refusing
# to start.
manifest($pkg, '50-broken.conf', '{ this is not json');
manifest($pkg, '50-good.conf',   '{"id":"good","backend":{"module":"A::Good"}}');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is_deeply(ids($exts), ['good'], 'a manifest that will not parse does not stop the others');
    like($log, qr/manifest invalid, ignoring: .*50-broken\.conf/, 'and is named in the log');
}

clear();

manifest($pkg, '50-jsonarray.conf', '["not", "an", "object"]');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is(scalar(@$exts), 0, 'valid JSON that is not an object is rejected');
    like($log, qr/top level is not a JSON object/, 'with a useful reason');
}

clear();

manifest($pkg, '50-badid.conf', '{"id":"Not Valid!","backend":{"module":"A::X"}}');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is(scalar(@$exts), 0, 'a malformed id is rejected');
    like($log, qr/bad or missing 'id'/, 'with a useful reason');
}

clear();

# A module name is the one manifest field that reaches require(). Anything that
# is not a plain Perl package name must never get that far.
for my $evil ('Acme::Hello; system("touch /tmp/pwned")',
              'Acme/Hello.pm',
              '../../../etc/passwd',
              "Acme::Hello\nprint 'x'") {
    clear();
    manifest_json($pkg, '50-evil.conf', {
        id => 'evil', backend => { module => $evil },
    });
    my ($exts) = load_from($pkg, $admin);
    is(scalar(@$exts), 0, "module name is rejected: " . _printable($evil));
}

clear();

# Asset names are interpolated into a URL that pveproxy serves without
# authentication, and into a filesystem path under /usr/share/proxmod/www.
for my $evil ('../../../etc/passwd', 'sub/dir.js', 'nodotjs', 'has space.js') {
    clear();
    manifest_json($pkg, '50-evilasset.conf', {
        id => 'evilasset', frontend => { assets => [$evil, 'ok.js'] },
    });
    my ($exts) = load_from($pkg, $admin);
    is_deeply($exts->[0]{frontend}{assets}, ['ok.js'],
        "asset name is rejected: " . _printable($evil));
}

sub _printable {
    my ($s) = @_;
    $s =~ s/\n/\\n/g;
    return $s;
}

clear();

# --- odds and ends --------------------------------------------------------

manifest($pkg, '50-empty.conf', '{"id":"nothing"}');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is(scalar(@$exts), 0, 'a manifest declaring neither backend nor frontend is ignored');
    like($log, qr/neither a usable backend nor frontend/, 'with a useful reason');
}

clear();

manifest($pkg, 'notes.txt', '{"id":"txt","backend":{"module":"A::Txt"}}');
manifest($pkg, '.hidden.conf', '{"id":"hidden","backend":{"module":"A::Hidden"}}');
manifest($pkg, '50-real.conf', '{"id":"real","backend":{"module":"A::Real"}}');
{
    my ($exts) = load_from($pkg, $admin);
    is_deeply(ids($exts), ['real'], 'only *.conf files are read, and not dotfiles');
}

clear();

manifest($pkg, '10-first.conf',  '{"id":"dup","order":10,"backend":{"module":"A::First"}}');
manifest($pkg, '20-second.conf', '{"id":"dup","order":20,"backend":{"module":"A::Second"}}');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is(scalar(@$exts), 1, 'a duplicate id loads once');
    is($exts->[0]{backend}{module}, 'A::First', 'the first by load order wins');
    like($log, qr/duplicate extension id 'dup'/, 'and the collision is reported');
}

clear();

manifest($pkg, '50-daemons.conf',
    '{"id":"picky","backend":{"module":"A::Picky","daemons":["pvedaemon","pvestatd"]}}');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is_deeply([ keys %{ $exts->[0]{backend}{daemons} } ], ['pvedaemon'],
        'an unsupported daemon is dropped from the list');
    like($log, qr/unknown host 'pvestatd'/, 'and reported');
}

clear();

# The command-line tools are hosts an extension may ask for by name. They are
# not daemons: proxmod only reaches them through a patch an operator enabled
# (ADR 0013), and an extension that wants to be there has to say so.
manifest($pkg, '50-cli.conf',
    '{"id":"cli","backend":{"module":"A::Cli","daemons":["pvedaemon","qm","pct","pvesh"]}}');
{
    my ($exts, $log) = load_from($pkg, $admin);
    is_deeply([ sort keys %{ $exts->[0]{backend}{daemons} } ],
        ['pct', 'pvedaemon', 'pvesh', 'qm'], 'a CLI may be named in backend.daemons');
    unlike($log, qr/unknown host/, 'and none of them is reported as unknown');
}

clear();

# THE DEFAULT MUST NOT DRIFT. Every extension written before the CLIs were
# accepted omits this key, and none of them was written with `qm` in mind. An
# upgrade must not start loading them into a command somebody types — least of
# all one that then wraps an API method and can refuse it.
manifest($pkg, '50-default-hosts.conf',
    '{"id":"defaulted","backend":{"module":"A::Defaulted"}}');
{
    my ($exts) = load_from($pkg, $admin);
    is_deeply([ sort keys %{ $exts->[0]{backend}{daemons} } ], ['pvedaemon', 'pveproxy'],
        'an absent daemons key still means the two daemons, and no CLI');
}

# A missing directory is normal, not an error: /etc/proxmod/extensions.d only
# exists once an administrator has put something in it.
{
    my ($exts, $log) = load_from("$root/does-not-exist");
    is_deeply($exts, [], 'a missing extension directory yields nothing');
    unlike($log, qr/warn/, 'and is not warned about');
}

# --- the registry fingerprint ---------------------------------------------
#
# Proxmod::Boot logs this at daemon startup and proxmod-verify recomputes it
# from disk, so that "an extension was installed but nothing restarted" becomes
# visible. Everything below is about what must and must not move it.

sub fp {
    my ($exts) = load_from($pkg, $admin);
    return Proxmod::Registry::fingerprint($exts);
}

clear();
manifest($pkg, '50-hello.conf',
    '{"id":"hello","version":"1.0","backend":{"module":"A::Hello"},"frontend":{"assets":["hello.js"]}}');

my $base = fp();
like($base, qr/\A[0-9a-f]{12}\z/, 'a fingerprint is twelve hex digits');
is(fp(), $base, 'and is the same for the same registry read twice');

# Every field below changes what a daemon would actually load, so every one of
# them has to change the fingerprint. A field that did not would be an
# extension change that silently never goes live.
my %moves = (
    'a new extension' =>
        sub { manifest($pkg, '60-other.conf', '{"id":"other","backend":{"module":"A::Other"}}') },
    'a changed version' =>
        sub { manifest($pkg, '50-hello.conf',
            '{"id":"hello","version":"1.1","backend":{"module":"A::Hello"},"frontend":{"assets":["hello.js"]}}') },
    'a changed order' =>
        sub { manifest($pkg, '50-hello.conf',
            '{"id":"hello","version":"1.0","order":10,"backend":{"module":"A::Hello"},"frontend":{"assets":["hello.js"]}}') },
    'a changed backend module' =>
        sub { manifest($pkg, '50-hello.conf',
            '{"id":"hello","version":"1.0","backend":{"module":"A::Elsewhere"},"frontend":{"assets":["hello.js"]}}') },
    'a narrowed daemon list' =>
        sub { manifest($pkg, '50-hello.conf',
            '{"id":"hello","version":"1.0","backend":{"module":"A::Hello","daemons":["pvedaemon"]},"frontend":{"assets":["hello.js"]}}') },
    'a changed frontend asset' =>
        sub { manifest($pkg, '50-hello.conf',
            '{"id":"hello","version":"1.0","backend":{"module":"A::Hello"},"frontend":{"assets":["goodbye.js"]}}') },
    'a removed extension' =>
        sub { clear() },
);

for my $what (sort keys %moves) {
    clear();
    manifest($pkg, '50-hello.conf',
        '{"id":"hello","version":"1.0","backend":{"module":"A::Hello"},"frontend":{"assets":["hello.js"]}}');
    $moves{$what}->();
    isnt(fp(), $base, "$what changes the fingerprint");
}

# The other half of the contract. A manifest that contributes nothing to what
# runs must not move the fingerprint, or every disabled extension on the host
# would cost a daemon restart it does not need.
clear();
manifest($pkg, '50-hello.conf',
    '{"id":"hello","version":"1.0","backend":{"module":"A::Hello"},"frontend":{"assets":["hello.js"]}}');
manifest($pkg, '70-off.conf', '{"id":"off","enabled":false,"backend":{"module":"A::Off"}}');
is(fp(), $base, 'a disabled extension does not change the fingerprint');

manifest($admin, '70-off.conf', '');
is(fp(), $base, 'and neither does masking one');

# Two daemons ask the same question and must get the same answer. pveproxy runs
# the frontend stage and pvedaemon does not, so anything derived from what each
# daemon loaded — a count, for instance — would differ between them for one
# registry. This is why the fingerprint is a function of the list alone.
clear();
manifest($pkg, '50-hello.conf',
    '{"id":"hello","version":"1.0","backend":{"module":"A::Hello"},"frontend":{"assets":["hello.js"]}}');
{
    my ($a) = load_from($pkg, $admin);
    my ($b) = load_from($pkg, $admin);
    is(Proxmod::Registry::fingerprint($a), Proxmod::Registry::fingerprint($b),
        'two independent loads of one registry agree');
}

is(Proxmod::Registry::fingerprint([]), Proxmod::Registry::fingerprint(undef),
    'an empty registry and no registry are the same thing');
isnt(Proxmod::Registry::fingerprint([]), $base, 'and are not the same as a populated one');

# --- inventory: what load() drops, and why -------------------------------
#
# load() answers the daemons' question and no other: what will be loaded. That
# makes it the wrong function for `proxmodctl list`, because an extension that
# is masked, disabled or unresolvable is exactly what the administrator running
# it is trying to find, and load() omitting it looks the same as it not being
# installed. inventory() reports the whole directory and labels each entry.

clear();
manifest($pkg, '50-live.conf',
    '{"id":"live","version":"1.0","backend":{"module":"A::Live"}}');
manifest($pkg, '51-off.conf',
    '{"id":"off","version":"1.0","enabled":false,"backend":{"module":"A::Off"}}');
manifest($pkg, '52-shadowed.conf',
    '{"id":"shadowed","version":"1.0","backend":{"module":"A::Shadowed"}}');
manifest($admin, '52-shadowed.conf', '');
manifest($pkg, '53-lonely.conf',
    '{"id":"lonely","version":"1.0","requires":["gone"],"backend":{"module":"A::Lonely"}}');

{
    my ($inv) = capture_log(sub {
        Proxmod::Registry::inventory(dirs => [$pkg, $admin]);
    });
    my %state = map { ($_->{id} // $_->{basename}) => $_->{state} } @$inv;

    is(scalar(@$inv), 4, 'every manifest on disk is reported, not just the live ones');
    is($state{live}, 'effective', 'the one the daemons will load');
    is($state{off}, 'disabled', 'the one that disabled itself');
    is($state{'52-shadowed.conf'}, 'masked', 'the one an admin masked from /etc');
    # This is the state with no other symptom: nothing logs at warn level, the
    # extension simply is not there.
    is($state{lonely}, 'unresolved', 'and the one dropped for a dependency that does not exist');

    my ($live) = load_from($pkg, $admin);
    is_deeply(ids($live), ['live'],
        'while load() still answers the daemons\' narrower question');
}
