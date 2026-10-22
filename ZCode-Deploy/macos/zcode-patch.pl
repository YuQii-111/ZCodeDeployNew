#!/usr/bin/env perl
# ============================================
# zcode-patch.pl  v2.1.0-mac
# ZCode six-patch core, ported 1:1 from deploy.ps1 v2.0 (Windows).
#
# The patch engine is intentionally pure ASCII (display strings in
# Chinese live in deploy.sh); it operates on raw bytes so multibyte
# UTF-8 content can never break the brace balancing.
#
# Usage:
#   zcode-patch.pl patch    <zcode.cjs> <persona-file> <outfile>
#       Apply all six patches. Prints machine lines:
#         PATCH<TAB>id<TAB>ok|skip|missing<TAB>function-name
#       Always writes <outfile> (BOM preserved from source).
#       Exit 0 = no missing, exit 2 = at least one missing.
#   zcode-patch.pl report   <zcode.cjs>
#       Print the six self-checks:
#         REPORT<TAB>ok|warn<TAB>index(1..6)
#   zcode-patch.pl sections <zcode.cjs>
#       List all injection sections and their producing functions.
# ============================================
use strict;
use warnings;

my $MARKER       = 'ZP:PERSONA';
my $IDENTITY_LIT = '"You are ZCode, an interactive coding agent"';
my $LIT_IDENTITY = 'name:"Agent Identity",source:"identity"';
my $LIT_DATE     = 'name:"Current Date",source:"current_date"';
my $LIT_SKILLS   = 'name:"Skills",source:"skills"';
my $LIT_USERCTX  = 'name:"Request User Context",source:"request_user_context"';

my $ID_RE = qr/[A-Za-z_\$][A-Za-z0-9_\$]*/;

# ---------- load / save ----------

sub load_raw {
    my ($file) = @_;
    open(my $fh, '<:raw', $file) or die "cannot read $file: $!\n";
    local $/;
    my $data = <$fh>;
    close($fh);
    $data = '' unless defined $data;
    my $bom = (length($data) >= 3
               && substr($data, 0, 1) eq "\xEF"
               && substr($data, 1, 1) eq "\xBB"
               && substr($data, 2, 1) eq "\xBF") ? 1 : 0;
    if ($bom) { $data = substr($data, 3); }
    return ($data, $bom);
}

sub save_raw {
    my ($file, $data, $bom) = @_;
    open(my $fh, '>:raw', $file) or die "cannot write $file: $!\n";
    print $fh "\xEF\xBB\xBF" if $bom;
    print $fh $data;
    close($fh) or die "close failed: $!\n";
}

# ---------- locating helpers (ports of Get-EnclosingFunction etc.) ----------

# Find the function whose body encloses $anchor. Window of $back chars,
# then brace-balancing from each candidate "{" (C-speed index() jumps).
sub enclosing_function {
    my ($content, $anchor, $back) = @_;
    $back = 20000 unless defined $back;
    return undef if $anchor <= 0;
    my $start = $anchor - $back;
    $start = 0 if $start < 0;
    my $head = substr($content, $start, $anchor - $start);
    my $re = qr/function\s+($ID_RE)\s*\(($ID_RE(?:\s*,\s*$ID_RE)*)?\)\s*\{/;
    my $best;
    while ($head =~ /$re/g) {
        my $name  = $1;
        my $param = defined($2) ? $2 : '';
        my $open  = $start + $-[0] + length($&) - 1;
        # brace-balance: find the "}" that closes the "{" at $open
        my ($depth, $close, $pos) = (0, -1, $open);
        while (1) {
            my $no = index($content, '{', $pos);
            my $nc = index($content, '}', $pos);
            last if $nc < 0;
            if ($no >= 0 && $no < $nc) { $depth++; $pos = $no + 1; }
            else {
                $depth--; $pos = $nc + 1;
                if ($depth == 0) { $close = $nc; last; }
            }
        }
        if ($close > $anchor) {
            $best = { name => $name, param => $param, brace => $open, close => $close };
        }
    }
    return $best;
}

# Port of Test-NullApplied: does the function enclosing $lit start with "return null;"?
sub null_applied {
    my ($content, $lit) = @_;
    my $idx = index($content, $lit);
    return 0 if $idx < 0;
    my $fn = enclosing_function($content, $idx);
    return 0 unless $fn;
    my $b = $fn->{brace} + 1;
    return 0 if $b >= length($content);
    my $len = length($content) - $b;
    $len = 12 if $len > 12;
    return substr($content, $b, $len) =~ /^return null;/ ? 1 : 0;
}

# Port of Get-PersonaExpr: JS expression that reads the persona file at runtime.
sub persona_expr {
    my ($path) = @_;
    my $js = $path;
    $js =~ s/\\/\\\\/g;
    $js =~ s/"/\\"/g;
    return '(function(){/*' . $MARKER . '*/try{return require("fs").readFileSync("' . $js . '","utf8")}catch(e){return null}})()';
}

# ---------- the six patches ----------
# Each returns (status, content, name) with status in ok|skip|missing.

# Patch 1: blank the "You are ZCode ..." identity literal in the CLI prefix.
sub patch_cli_prefix {
    my ($c) = @_;
    return ('skip', $c, '') if index($c, $IDENTITY_LIT) < 0;
    my $rx = qr/($ID_RE)=\Q$IDENTITY_LIT\E/;
    return ('missing', $c, '') unless $c =~ /$rx/;
    my $name = $1;
    my $rep  = $name . '=""';
    substr($c, $-[0], $+[0] - $-[0]) = $rep;
    return ('ok', $c, $name);
}

# Patch 2: make customSystemPrompt read the external persona file.
# (The backreference \1 is why this tool is perl and not bash.)
sub patch_custom_prompt {
    my ($c, $expr) = @_;
    my $rx = qr/($ID_RE)=this\.config\.customSystemPrompt\?\.trim\(\),($ID_RE)=!!\1,/;
    if ($c !~ /$rx/) {
        return ('skip', $c, '') if index($c, $MARKER) >= 0;
        return ('missing', $c, '');
    }
    my ($v, $f) = ($1, $2);
    my $rep = $v . '=' . $expr . '?.trim(),' . $f . '=!!' . $v . ',';
    substr($c, $-[0], $+[0] - $-[0]) = $rep;
    return ('ok', $c, $v);
}

# Patch 3: Agent Identity section reads the persona file (original kept as fallback).
sub patch_agent_identity {
    my ($c, $expr) = @_;
    my $idx = index($c, $LIT_IDENTITY);
    return ('missing', $c, '') if $idx < 0;
    my $fn = enclosing_function($c, $idx);
    return ('missing', $c, '') unless $fn;
    my $body_start = $fn->{brace} + 1;
    my $seg = substr($c, $body_start, $idx - $body_start);
    return ('skip', $c, $fn->{name}) if index($seg, $MARKER) >= 0;
    my $rx_let = qr/let\s+($ID_RE)\s*=\s*([^;]{1,120});/;
    my $last;
    while ($seg =~ /$rx_let/g) {
        $last = [$1, $2, $-[0], $+[0] - $-[0]];
    }
    return ('missing', $c, $fn->{name}) unless $last;
    my ($var, $orig) = ($last->[0], $last->[1]);
    return ('skip', $c, $fn->{name}) if index($orig, $MARKER) >= 0;
    my $abs = $body_start + $last->[2];
    my $rep = 'let ' . $var . ';try{' . $var . '=' . $expr . '}catch(_ze){' . $var . '=' . $orig . '}';
    substr($c, $abs, $last->[3]) = $rep;
    return ('ok', $c, $fn->{name});
}

# Patches 4/5/6: force the section-producing function to return null.
sub patch_null_section {
    my ($c, $lit) = @_;
    my $idx = index($c, $lit);
    return ('missing', $c, '') if $idx < 0;
    my $fn = enclosing_function($c, $idx);
    return ('missing', $c, '') unless $fn;
    my $b = $fn->{brace} + 1;
    return ('missing', $c, $fn->{name}) if $b >= length($c);
    my $len = length($c) - $b;
    $len = 12 if $len > 12;
    return ('skip', $c, $fn->{name})
        if substr($c, $b, $len) =~ /^return null;/;
    substr($c, $b, 0) = 'return null;';
    return ('ok', $c, $fn->{name});
}

# ---------- report (port of Get-PatchReport) ----------

sub report_lines {
    my ($c) = @_;
    my @out;
    push @out, [ (index($c, $IDENTITY_LIT) < 0) ? 1 : 0, 1 ];
    push @out, [ (index($c, $MARKER) >= 0) ? 1 : 0, 2 ];
    my $id_ok = null_applied($c, $LIT_IDENTITY)
             || (index($c, $MARKER) >= 0 && null_applied($c, $LIT_DATE));
    push @out, [ $id_ok ? 1 : 0, 3 ];
    push @out, [ null_applied($c, $LIT_DATE)    ? 1 : 0, 4 ];
    push @out, [ null_applied($c, $LIT_SKILLS)  ? 1 : 0, 5 ];
    push @out, [ null_applied($c, $LIT_USERCTX) ? 1 : 0, 6 ];
    return @out;
}

# ---------- sections (port of Show-Sections) ----------

sub show_sections {
    my ($c) = @_;
    my $rx = qr/name:"([^"]{1,48})",source:"([^"]{1,48})",injectionTarget:"([^"]{1,24})"/;
    my $i = 0;
    while ($c =~ /$rx/g) {
        $i++;
        my ($nm, $src, $tgt) = ($1, $2, $3);
        my $fn = enclosing_function($c, $-[0]);
        my $fname = $fn ? $fn->{name} : '?';
        printf "%2d. %-30s source=%-26s target=%-12s fn=%s\n", $i, $nm, $src, $tgt, $fname;
    }
    print "  (no injection sections recognized)\n" if $i == 0;
}

# ============================================
# main
# ============================================

my $mode = shift @ARGV || '';
if ($mode ne 'patch' && $mode ne 'report' && $mode ne 'sections') {
    print STDERR "usage: zcode-patch.pl patch <zcode.cjs> <persona> <outfile>\n";
    print STDERR "       zcode-patch.pl report <zcode.cjs>\n";
    print STDERR "       zcode-patch.pl sections <zcode.cjs>\n";
    exit 64;
}

if ($mode eq 'sections') {
    my ($cfile) = @ARGV;
    die "usage: zcode-patch.pl sections <zcode.cjs>\n" unless defined $cfile;
    my ($c) = load_raw($cfile);
    show_sections($c);
    exit 0;
}

if ($mode eq 'report') {
    my ($cfile) = @ARGV;
    die "usage: zcode-patch.pl report <zcode.cjs>\n" unless defined $cfile;
    my ($c) = load_raw($cfile);
    for my $r (report_lines($c)) {
        print "REPORT\t" . ($r->[0] ? 'ok' : 'warn') . "\t$r->[1]\n";
    }
    exit 0;
}

# patch mode
my ($cfile, $pfile, $outfile) = @ARGV;
die "usage: zcode-patch.pl patch <zcode.cjs> <persona> <outfile>\n"
    unless defined $cfile && defined $pfile && defined $outfile;

my ($c, $bom) = load_raw($cfile);
my $expr = persona_expr($pfile);

my @order = (
    [1, 'cli_prefix',    sub { patch_cli_prefix($_[0]) }],
    [2, 'custom_prompt', sub { patch_custom_prompt($_[0], $expr) }],
    [3, 'agent_identity',sub { patch_agent_identity($_[0], $expr) }],
    [4, 'null_date',     sub { patch_null_section($_[0], $LIT_DATE) }],
    [5, 'null_skills',   sub { patch_null_section($_[0], $LIT_SKILLS) }],
    [6, 'null_userctx',  sub { patch_null_section($_[0], $LIT_USERCTX) }],
);

my $missing = 0;
for my $step (@order) {
    my ($id, $key, $sub) = @$step;
    my ($status, $newc, $name) = $sub->($c);
    $c = $newc;
    $missing++ if $status eq 'missing';
    print "PATCH\t$id\t$status\t$name\n";
}

save_raw($outfile, $c, $bom);
exit($missing > 0 ? 2 : 0);
