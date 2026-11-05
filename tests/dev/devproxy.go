// Development only. Stands in for the UGOS gateway: serves the frontend and
// forwards /api to the backend with the headers the gateway would set.
package main

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
)

func main() {
	backend, err := url.Parse("http://127.0.0.1:21847")
	if err != nil {
		log.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(backend)
	http.Handle("/api/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Set("Ugreen-User-Type", "admin")
		r.Header.Set("Ugreen-User-Name", "dev")
		proxy.ServeHTTP(w, r)
	}))
	http.Handle("/", http.FileServer(http.Dir("/src/app/rootfs_common/www")))
	log.Fatal(http.ListenAndServe(":8099", nil))
}
