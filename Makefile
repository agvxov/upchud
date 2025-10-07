serve:
	@echo "(Serving on port 8080)"
	lighttpd -D -f lighttpd.conf

front:
	@echo "(Serving on port 8081)"
	lighttpd -D -f example_frontend.lighttpd.conf

clean:
	-${RM} -frfr out/
	-${RM} errors.log
