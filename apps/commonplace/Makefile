CFLAGS = -O2 -Wall -Wextra -fPIC
ERLANG_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
NIF_CFLAGS = -I$(ERLANG_PATH)

ifeq ($(shell uname), Darwin)
	NIF_LDFLAGS = -dynamiclib -undefined dynamic_lookup
else
	NIF_LDFLAGS = -shared
endif

PRIV_DIR = $(MIX_APP_PATH)/priv

all: $(PRIV_DIR)/flock_nif.so

$(PRIV_DIR)/flock_nif.so: c_src/flock_nif.c
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) $(NIF_CFLAGS) $(NIF_LDFLAGS) -o $@ $<

clean:
	rm -f $(PRIV_DIR)/flock_nif.so
