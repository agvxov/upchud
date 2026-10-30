#!/usr/bin/tclsh

# molested by Claude to remove the most obvious RCE on earth

# --- [Config] ---

# Directory to place the files to. Prefer an absolute path: relative paths
# depend on the working directory of whatever spawns the CGI.
# Must be on one filesystem (uploads are staged here and hard-linked/renamed).
set outdir "out/"

# Method for naming uploads.
# Options are:
#   simple - just restrict into $::label_char_set
#   mangle - random name (never clobbers: retries up to $::max_save_attempts)
#   hash   - sha1 prefix, deduplicates identical content (needs sha1sum and cmp),
#            extends name when collision occurs instead of clobbering
set labeling_scheme "hash"

# The length of the generated base name. Applies to mangled and hashed names.
set auto_label_length 4
# from memory, higher is better for mangle.
# a small number is fine for hash due to its auto-extending strategy.

# The characters which are allowed to be used in upload names.
#  '.' is always implicitly allowed. Do NOT specify '.' or '/', saar.
set label_char_set {0123456789abcdefghijklmnopqrstuvwxyz-_}
#set label_char_set {0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZáÁéóÓöÖőŐúÚüÜűŰ -_}

# Every random name has a chance to collide with a previously saved file.
# Theoretically if you don't clean your uploads and both your
# $::auto_label_length and $::label_char_set are small, you could end up with a dead lock.
# This value is the fail-safe.

# higher values don't yield any value except in choked mangling.
set max_save_attempts 10

# Only used by the "simple" scheme: when off, uploading an existing name is an
# error; when on, it clobbers. "mangle" and "hash" never clobber.
#  THIS is a claude-ism in being useless,
# this really should just enable clobbering within our auto_label_length (which is a terrible name)
set overwrite_uploads 0

# Reject requests larger than this many bytes (0 = no limit). POST bodies are
# held in memory (about 2x), so keep this sane, and also set
# client_max_body_size in nginx. (which in up.chud.cyou is set as 100MiB.)
set max_upload_bytes [expr 1024 * 1024 * 256]


# The output of this function is (ideally) what the user will see.
# I have provided a few default behaviours, but you do you champ.
proc send_success {upload_name} {
    proc simple {upload_name} {
        set scheme $::env(REQUEST_SCHEME)
        set host   $::env(HTTP_HOST)
        set url "$scheme://$host/$upload_name"

        puts "Status: 200 OK\r"
        puts "Content-Type: text/plain\r"
        puts "\r"
        puts "$url"
    }

    proc link {upload_name} {
        set scheme $::env(REQUEST_SCHEME)
        set host   $::env(HTTP_HOST)
        set url [html_escape "$scheme://$host/$upload_name"]

        puts "Status: 200 OK\r"
        puts "Content-Type: text/html\r"
        puts "\r"
        puts "<a href=\"$url\">$url</a>"
    }

    proc redirect {upload_name} {
        set scheme $::env(REQUEST_SCHEME)
        set host   $::env(HTTP_HOST)
        set url "$scheme://$host/$upload_name"

        puts "Status: 303 See Other\r"
        puts "Location: $url\r"
        puts "Content-Type: text/plain\r"
        puts "\r"
        puts "Redirecting to $url"
    }

    set upload_name [file tail $upload_name]
    set agent $::env(HTTP_USER_AGENT)

    # Curl client aka terminal
    if {[regexp -nocase {curl} $agent]} {
        simple $upload_name
    # Browser clients
    } else {
        link $upload_name
        #redirect $upload_name
    }
}



# ---
# --- [Core] ---
# ---
fconfigure stdin -translation binary -encoding binary

# Staging file currently in $::outdir; removed on any error exit.
set temp_path ""

proc html_escape {s} {
    return [string map [list & &amp\; < &lt\; > &gt\; \" &quot\; ' &#39\;] $s]
}

proc respond_error {status} {
    if { $::temp_path ne "" } { catch { file delete $::temp_path } }
    puts "Status: $status\r"
    puts "Content-Type: text/plain\r"
    puts "\r"
    puts $status
    exit 1
}

proc raise_fatal {} {
    respond_error "400 Bad Request"
}

proc random_string {len chars} {
    # /dev/urandom, 32 bits per character; modulo bias is negligible.
    set n [string length $chars]
    set f [open /dev/urandom rb]
    set data [read $f [expr {4 * $len}]]
    close $f
    binary scan $data iu* nums
    set s ""
    foreach v $nums { append s [string index $chars [expr {$v % $n}]] }
    return $s
}

proc restrict_string {s} {
    set chars $::label_char_set
    set n [string length $chars]
    set r ""

    foreach c [split $s ""] {
        if { $c ne "." && [string first $c $chars] == -1 } {
            # '.JPG' should become '.jpg', not digit soup
            set l [string tolower $c]
            if { [string length $l] == 1 && [string first $l $chars] != -1 } {
                set c $l
            } else {
                scan $c %c code
                set c [string index $chars [expr { $code % $n }]]
            }
        }
        append r $c
    }

    return $r
}

proc get_contents_hash {path} {
    return [lindex [exec sha1sum $path] 0]
}

# Atomically give $tmp the name $out without clobbering. link(2) fails with
# EEXIST if $out exists, so concurrent uploads cannot race. Returns 1 on success.
proc publish_new {tmp out} {
    if { [catch { file link -hard $out $tmp }] } { return 0 }
    file delete $tmp
    set ::temp_path ""
    return 1
}

# Pick the final name for the staged upload and move it there. Returns the path.
proc commit_upload {orig_name tmp} {
    # NOTE: `file extension` only returns the last extension, but `.tar.gz` is relevant for us
    set extension ""
    regexp {(\..+)$} $orig_name -> extension
    if { [string length $extension] > 32 } { set extension [file extension $orig_name] }
    set extension [restrict_string $extension]

    switch -- $::labeling_scheme {
        simple {
            # Leading dots stripped: no '.', '..', hidden files, or collisions with staging names.
            set name [string range [string trimleft [restrict_string $orig_name] .] 0 127]
            if { $name eq "" } { raise_fatal }
            set out "$::outdir/$name"
            if { $::overwrite_uploads } {
                file rename -force $tmp $out
                set ::temp_path ""
            } elseif { ![publish_new $tmp $out] } {
                raise_fatal
            }
            return $out
        }
        mangle {
            for { set tries 1 } { $tries <= $::max_save_attempts } { incr tries } {
                set out "$::outdir/[random_string $::auto_label_length $::label_char_set]$extension"
                if { [publish_new $tmp $out] } { return $out }
            }
            raise_fatal
        }
        hash {
            set h [get_contents_hash $tmp]
            set max [string length $h]
            set start [expr { max(1, min($::auto_label_length, $max)) }]
            for { set n $start } { $n <= $max } { incr n } {
                set out "$::outdir/[string range $h 0 [expr {$n - 1}]]$extension"
                if { [publish_new $tmp $out] } { return $out }
                # Name taken: identical content is a dedupe hit; different
                # content is a prefix collision, so retry with a longer prefix.
                if { ![catch { exec cmp -s $tmp $out }] } {
                    file delete $tmp
                    set ::temp_path ""
                    return $out
                }
            }
            raise_fatal
        }
        default {
            respond_error "500 Internal Server Error"
        }
    }
}

# Create the staging file inside $::outdir (same filesystem, so the final
# link/rename is atomic and never exposes a partial file under its public name).
proc open_temp {} {
    for { set i 0 } { $i < 10 } { incr i } {
        set p "$::outdir/.tmp.[random_string 16 0123456789abcdef]"
        if { ![catch { open $p {WRONLY CREAT EXCL BINARY} } f] } {
            set ::temp_path $p
            return $f
        }
    }
    respond_error "500 Internal Server Error"
}

proc main {} {
    set method $::env(REQUEST_METHOD)

    set content_length 0
    if { [info exists ::env(CONTENT_LENGTH)] && [regexp {^[0-9]{1,12}$} $::env(CONTENT_LENGTH)] } {
    set content_length [lindex [scan $::env(CONTENT_LENGTH) %ld] 0]
    }
    if { $::max_upload_bytes > 0 && $content_length > $::max_upload_bytes } {
        respond_error "413 Payload Too Large"
    }

    if { $method ne "PUT" && $method ne "POST" } { raise_fatal }

    if { ![file isdirectory $::outdir] } { file mkdir $::outdir }

    if { $method eq "PUT" } {
        # No query string, last path component only.
        set uri [lindex [split $::env(REQUEST_URI) ?] 0]
        set original_name [file tail $uri]

        set f [open_temp]
	if { $content_length > 0 } {
	    if { [chan copy stdin $f -size $content_length] != $content_length } { close $f; raise_fatal }
	}
	close $f
    } else {
        # NOTE:
        #  we must parse multipart/form-data;
        #  see: RFC 7578 (https://www.rfc-editor.org/rfc/rfc7578)
        if { ![info exists ::env(CONTENT_TYPE)]
          || ![regexp {boundary="?([^";]+)"?} $::env(CONTENT_TYPE) -> boundary] } {
            raise_fatal
        }
        set delimiter "\r\n--$boundary"

        # NOTE:
        #  It is not expected to have more then one part;
        #   why the hell would someone post multiple fields?
        #  So: single-part bodies only. Tcl expands binary strings several
        #  times over when searched or sliced (100 MB -> ~800 MB RSS), so
        #  only the part header is held in memory; the payload streams
        #  straight to the staging file and the closing delimiter is
        #  trimmed off the end afterwards.
        set head [read stdin [expr { min($content_length, 65536) }]]
        if { [string first "--$boundary" $head] != 0 } { raise_fatal }

        set hdr_end [string first "\r\n\r\n" $head]
        if { $hdr_end < 0 } { raise_fatal }
        set header [string range $head 0 $hdr_end]

        # NOTE:
        #  the filename parameter is not guaranteed to be provided
        #  and not guaranteed to be quoted
        if { ![regexp {filename="([^"]*)"} $header -> original_name] } { set original_name "" }
        set original_name [file tail $original_name]

        set f [open_temp]
        puts -nonewline $f [string range $head [expr {$hdr_end + 4}] end]
        set rest [expr { $content_length - [string length $head] }]
        if { $rest > 0 } { chan copy stdin $f -size $rest }
        close $f

        # Trim "\r\n--boundary--\r\n" (and any epilogue). Exactly one delimiter
        # may appear in the tail window, and it must be the closing one;
        # anything else means a multi-part body, which is refused.
        set size [file size $::temp_path]
        set win  [expr { min($size, 65536) }]
        set f [open $::temp_path {RDWR BINARY}]
        seek $f [expr {$size - $win}]
        set tail [read $f $win]
        set dpos [string last $delimiter $tail]
        set dend [expr {$dpos + [string length $delimiter]}]
        if { $dpos < 0
          || [string first $delimiter $tail] != $dpos
          || [string range $tail $dend [expr {$dend + 1}]] ne "--" } {
            close $f
            raise_fatal
        }
        chan truncate $f [expr {$size - $win + $dpos}]
        close $f
    }

    send_success [commit_upload $original_name $::temp_path]
}

if { [catch main err] } {
    puts stderr "upchud: $err"
    respond_error "500 Internal Server Error"
}

## Notes
# This is a very useful debug snippet:
#
#   foreach name [lsort [array names ::env]] {
#       puts stderr "$name = $::env($name)"
#   }
# hecking public domain CHUD!
