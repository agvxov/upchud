serve:
	lighttpd -D -f lighttpd.conf

front:
	lighttpd -D -f example_frontend.lighttpd.conf

clean:
	-${RM} -frfr out/
	-${RM} errors.log
