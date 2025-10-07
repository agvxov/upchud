#!/usr/bin/tclsh

# ---
# --- [Config] ---
# ---
# Directory to place the files to.
set outdir "out/"
# Method for naming uploads.
# Options are:
#   simple - just restrict into $::label_char_set
#   mangle - random name
#   hash   - deduplicates, but requires tcllib
set labeling_scheme "simple"
# The lenght of the generated base name. Applies to mangled and hashed names.
set auto_label_lenght 6
# The characters which are allowed to be used in upload names.
#  '.' is always implicitly allowed. Do NOT specify '.' or '/'.
set label_char_set {0123456789abcdefghijklmnopqrstuvwxyz}
#set label_char_set {0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZáÁéóÓöÖőŐúÚüÜűŰ -_}
# Every random name has a chance to collide with a previously saved file.
# Theoretically if you don't clean your uploads and both your
# $::auto_label_lenght and $::label_char_set are small, you could end up with a dead lock.
# This value is the fail-safe.
set max_save_attempts 20
# Trying to overwrite an upload will yield an error by default. When on, collisons clobber.
#  With mangling, its an alternative to $::max_save_attempts.
#  With hashing, required for deduping.
set overwrite_uploads 0
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
        set url "$scheme://$host/$upload_name"

        puts "Status: 200 OK\r"
        puts "Content-Type: text/html\r"
        puts "\r"
        puts "<a href=$url>$url</a>"
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
set method         $::env(REQUEST_METHOD)
set content_length $::env(CONTENT_LENGTH)

fconfigure stdin -translation binary -encoding binary

proc raise_fatal {} {
    puts "Status: 400 Bad Request\r"
    puts "Content-Type: text/plain\r\n"
    puts "400 Bad Request"
    exit 1
}

proc splitstr {text delim} {
    # I hate the antichrist;
    # why the fuck isnt this standard?
    # what fucking moron thought the lack of splitting would be a good addition to Tcl?

    set result {}
    set dlen [string length $delim]
    set start 0

    while {[set idx [string first $delim $text $start]] >= 0} {
        lappend result [string range $text $start [expr {$idx - 1}]]
        set start [expr {$idx + $dlen}]
    }

    lappend result [string range $text $start end]
    return $result
}

proc get_out_name {orig_name temp_path} {
    proc restrict_string {s} {
        set r ""

        for {set i 0} {$i < [string length $s]} {incr i} {
            set c [string index $s $i]

            if {[string first $c $::label_char_set] == -1 && $c ne "."} {
                binary scan $c c code
                set c [
                    string index \
                        $::label_char_set \
                        [expr { $code % [string length $::label_char_set] }]
                ]
            }

            append r $c
        }

        return $r
    }

    proc get_random_name {} {
        set chars $::label_char_set
        set name ""
        for {set i 0} {$i < $::auto_label_lenght} {incr i} {
            append name [string index $chars [expr {int(rand()*[string length $chars])}]]
        }
        return $name
    }

    proc get_contents_hash {path} {
        package require sha1
        return [sha1::sha1 -filename $path -hex]
    }

    # NOTE: `file extension` only returns the last extension, but `.tar.gz` is relevant for us
    #set extension [file extension $orig_name]
    set extension ""
    regexp {(\..+)$} $orig_name -> extension

    if { $::labeling_scheme == "simple" } {
        set out_name $::outdir/[restrict_string $orig_name]
        if { ! $::overwrite_uploads && [file exists $out_name] } {
            raise_fatal
        }
    } elseif { $::labeling_scheme == "mangle" } {
        set restricted_extension [restrict_string $extension]
        set name_found 0
        for { set tries 1 } { $tries <= $::max_save_attempts } { incr tries } {
            set out_name "$::outdir/[get_random_name]$restricted_extension"
            if { $::overwrite_uploads || ![file exists $out_name] } {
                set name_found 1
                break
            }
        }
        if { ! $name_found } {
            raise_fatal
        }
    } elseif { $::labeling_scheme == "hash" } {
        set out_name [get_contents_hash $temp_path]
        set out_name [string range $out_name 0 [expr {$::auto_label_lenght-1}]]
        set out_name $out_name$extension
        set out_name [restrict_string $out_name]
        set out_name "$::outdir/$out_name"
        if { ! $::overwrite_uploads && [file exists $out_name] } {
            raise_fatal
        }
    }

    return $out_name
}

if { $method eq "PUT" } {
    set original_name [file tail $::env(REQUEST_URI)]

    proc copy_stdin {out_name} {
        set f [open $out_name "wb"]
        fconfigure $f -translation binary -encoding binary
        chan copy stdin $f
        close $f
    }
    set write_file copy_stdin

} elseif { $method eq "POST" } {
    # NOTE:
    #  we must parse multipart/form-data;
    #  see: RFC 7578 (https://www.rfc-editor.org/rfc/rfc7578)
    regexp {boundary=(.+)} $::env(CONTENT_TYPE) -> BOUNDARY
    set BOUNDARY "\r\n--$BOUNDARY"

    set raw [read stdin $::content_length]

    # NOTE:
    #  It is not expected to have more then one part;
    #   why the hell would someone post multiple fields?
    #  However, it becomes a problem at somepoint,
    #   we simply need to find the one part that contains
    #   'name="file"' on the first line, where 'file'
    #   is the field name specified on the form
    #   (the example uses 'file' as a literal).
    set parts [splitstr $raw $BOUNDARY]
    set part [lindex $parts 0]

    if { $part eq "" } { raise_fatal }

    set delim "\r\n\r\n"
    set idx [string first $delim $part]
    set header [string range $part 0 $idx]
    set body   [string range $part [expr {$idx + [string length $delim]}] end]

    # NOTE:
    #  the filename parameter is not guaranteed to be provided
    #  and not guaranteed to be quoted
    if {![regexp {filename="(.+)"} $header -> original_name]} { set original_name "" }
    set original_name [file tail $original_name]

    proc write_body {out_name} {
        set f [open $out_name "wb"]
        fconfigure $f -translation binary -encoding binary
        puts -nonewline $f $::body
        close $f
    }
    set write_file write_body

} else {
    raise_fatal
}

if { ![file isdirectory $outdir] } { file mkdir $outdir }
close [file tempfile temp_path]
eval $write_file $temp_path
set output_name [get_out_name $original_name $temp_path]
file rename -force $temp_path $output_name

send_success $output_name

## Notes
# This is a very useful debug snippet:
#
#   foreach name [lsort [array names ::env]] {
#       puts stderr "$name = $::env($name)"
#   }
