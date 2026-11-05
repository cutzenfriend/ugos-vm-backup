// Backend of the VM Backup app for UGOS. It runs unprivileged in the app sandbox
// and only stores settings. Backups are done by the root script ugvm-backup.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func requireEnv(name string) string {
	value := os.Getenv(name)
	if value == "" {
		log.Fatalf("environment variable %s is not set", name)
	}
	return value
}

func main() {
	port := flag.Int("port", 21847, "HTTP port declared in project.yaml")
	listen := flag.String("listen", "127.0.0.1", "address to listen on")
	flag.Parse()

	server := &Server{
		sharedDir:       requireEnv("UGAPP_SHARED_DIR"),
		dataDir:         requireEnv("UGAPP_DATA_DIR"),
		installDir:      requireEnv("UGAPP_INSTALL_DIR"),
		hostPathAllowed: isAllowedHostPath,
	}

	httpServer := &http.Server{
		Addr:              net.JoinHostPort(*listen, strconv.Itoa(*port)),
		Handler:           server.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		<-ctx.Done()
		// UGOS sends SIGKILL after 10 seconds.
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdown); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()

	log.Printf("listening on %s", httpServer.Addr)
	if err := httpServer.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
