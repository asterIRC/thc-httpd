#!/usr/bin/env tclsh8.6

lappend auto_path "[pwd]/lib"
package require fileutil::magic::mimetype
package require uid
package require Expect
package require tls

namespace eval config {
	array set main {}
}
source httpd.conf

#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are
#  met:
#  
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above
#    copyright notice, this list of conditions and the following disclaimer
#    in the documentation and/or other materials provided with the
#    distribution.
#  * Neither the name of the AsterIRC Project nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
#  
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
#  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#  

trap rehash SIGUSR1

set pfile [open "./httpd.pid" w]
puts -nonewline $pfile [pid]
puts [pid]
close $pfile

proc rehash {} {
	uplevel "1" source httpd.conf
}

proc sendfile {tochan filename} {
	set fp [open $filename r]
	fconfigure $fp -encoding binary -translation {binary binary}
        for {set x 0} {![eof $fp]} {incr x} {
                puts -nonewline $tochan [read $fp]
                flush $tochan
        }
	close $fp
}

proc sendfromchan {tochan fromchan} {
	# Requires fromchan already be open.
	# closes fromchan.
	for {set x 0} {![eof $fromchan]} {incr x} {
		puts -nonewline $tochan [read -nonewline $fromchan]
		flush $tochan
	}
	catch {close $fromchan} zigi
}

array set waiting {}
array set header {}
array set urls {}
array set qtypes {}
array set qvers {}
array set postdata {}
array set filepfx {}
array set nonl {}

proc readrreq {chan addr} {
	set msg [read $chan]
	set mssg [split $msg "\n"]
	foreach {mag} $mssg {
		readreq $chan $addr [string trim $mag "\r"]
	}
}

proc readreq {chan addr msg} {
	global waiting header env urls qtypes postdata filepfx qvers nonl
	set qtype [lindex $msg 0]
	switch -regexp $qtype {
		"POST" {set qtypes($chan) $qtype;set qvers($chan) [lindex $msg 2];set urls($chan) [lindex $msg 1]}
		"GET" {set qtypes($chan) $qtype;set qvers($chan) [lindex $msg 2];set urls($chan) [lindex $msg 1]}
		".*:" {dict set header($chan) [string tolower [string trim [lindex $msg 0] ":"]] [lindex $msg 1]}
	}
	#if {"post"==$qtypes($chan) && $qtype != "post" && $qtype != "get"} {append postdata($chan) "$msg\r\n"}
	#if {[info exists qtypes($chan)]} {if {"POST"==$qtypes($chan)} {puts stdout $msg}}
	if {[info exists qtypes($chan)] && [info exists nonl($chan)]} {if {"POST"==$qtypes($chan) && $nonl($chan) == 1} {append postdata($chan) $msg;append postdata($chan) "\r\n";puts stdout $msg;set waiting($chan) 0}}
	if {[info exists header($chan)]} {
	if {![info exists filepfx($chan)]} {
	foreach {k v} $header($chan) {
		if {[string tolower $k] == "host"} {
			foreach {reg dir} $::config::main(root) {
				if {[regexp $reg $v ->]} {
					set filepfx($chan) $dir
				}
			}
		}
	} }
	} else {
		set filepfx($chan) [dict get $::config::main(root) default]
	}
	if {![info exists nonl($chan)] && $msg == "" && [info exists qtypes($chan)]} {
		set nonl($chan) 0
	}
	if {[info exists nonl($chan)] && $msg == "" && [info exists qtypes($chan)]} {
		incr nonl($chan)
	}
	if {[info exists nonl($chan)] && [info exists qtypes($chan)]} {
		puts stdout "$nonl($chan) $qtypes($chan)"
		if {$nonl($chan) >= 1} {
			set waiting($chan) 0
		}
	}
	if {!$waiting($chan) && [info exists qtypes($chan)]} {
		set env(SERVER_SOFTWARE) "tclhttpd/0.1"
		set url [lindex [split $urls($chan) "?"] 0]
		set cgiparm [lindex [split $urls($chan) "?"] 1]
		set iscgi 0
		if {$url == "/"} {
			set url $::config::main(index)
		}
		foreach {reg prog} $::config::main(cgi) {
			if {[regexp $reg $url ->]} {
				set env(QUERY_STRING) $cgiparm
				set env(DOCUMENT_ROOT) $filepfx($chan)
				if {[string match -nocase "*POST*" $qtypes($chan)]} {set qtype POST} {set qtype GET}
				set env(REQUEST_METHOD) $qtype
				set env(REMOTE_ADDR) $addr
				set env(REDIRECT_STATUS) 1
				if {[dict exists headers($chan) content-length]} {set env(CONTENT_LENGTH) [dict get headers($chan) content-length]}
				if {[dict exists headers($chan) content-type]} {set env(CONTENT_TYPE) [dict get headers($chan) content-type]}
				set env(SCRIPT_FILENAME) $filepfx($chan)${url}
				if {[dict exists headers($chan) cookie]} {set env(HTTP_COOKIE) [dict get headers($chan) cookie]}

				set fromc [open |[list $prog $filepfx($chan)${url}] r+]
				if {[info exists postdata($chan)]} {puts $fromc $postdata($chan)}
				puts -nonewline $chan "HTTP/1.1 200 Attempting to send results of script\r\n"
				sendfromchan $chan $fromc
				close $chan
				unset env(QUERY_STRING)
				unset env(DOCUMENT_ROOT)
				unset env(REQUEST_METHOD)
				unset env(REMOTE_ADDR)
				if {[dict exists headers($chan) content-length]} {unset env(CONTENT_LENGTH)}
				if {[dict exists headers($chan) content-type]} {unset env(CONTENT_TYPE)}
				unset env(SCRIPT_FILENAME)
				unset filepfx($chan)
				unset qtypes($chan)
				if {[info exists postdata($chan)]} {unset postdata($chan)}
				set iscgi 1
				break
			}
		}
		if {!$iscgi} {
			puts -nonewline $chan "HTTP/1.1 200 Attempting to send file\r\n"
			puts -nonewline $chan "Content-Length: [expr {[file size $filepfx($chan)${url}]}]\r\n"
			puts -nonewline $chan "Content-Type: [::fileutil::magic::mimetype $filepfx($chan)${url}]\r\n\r\n"
			sendfile $chan "$filepfx($chan)${url}"
			close $chan
		}
	}
}

proc acceptconn {chan addr port} {
	global waiting postdata
	fconfigure $chan -blocking 0 -buffering none -encoding binary -translation {binary binary}
	set waiting($chan) 1
	set postdata($chan) ""
	fileevent $chan readable [list readrreq $chan $addr]
}

proc sacceptconn {chan addr port} {
	global waiting postdata
	fconfigure $chan -blocking 1 -buffering none
	::tls::handshake $chan
	fconfigure $chan -blocking 0 -buffering none -encoding binary -translation {binary binary}

	set waiting($chan) 1
	set postdata($chan) ""
	fileevent $chan readable [list readrreq $chan $addr]
}

foreach {host port} $::config::main(port) {
	socket -server acceptconn -myaddr $host $port
}

if {[info exists ::config::main(sslport)]} {
	::tls::init -require 0 -request 0 -certfile httpd.pem -keyfile httpd.pem
	foreach {host port} $::config::main(sslport) {
		::tls::socket -server sacceptconn -myaddr $host $port
	}
}

if {![setusergroup $::config::main(runas)]} {die "Fucking CANNOT RUN AS ROOT!"}
puts [getuid]
puts [geteuid]
vwait forever
