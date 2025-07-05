serve:
	lighttpd -D -f lighttpd.conf

front:
	lighttpd -D -f example.lighttpd.conf

clean:
	-${RM} -frfr out/
	-${RM} errors.log
