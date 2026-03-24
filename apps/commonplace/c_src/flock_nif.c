#include <erl_nif.h>

static ErlNifFunc nif_funcs[] = {};

ERL_NIF_INIT(Elixir.Commonplace.Sync.Flock, nif_funcs, NULL, NULL, NULL, NULL)
