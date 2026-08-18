#include <erl_nif.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

static ErlNifResourceType *FD_RESOURCE;

typedef struct {
    int fd;
    int closed;
} FdResource;

static void fd_resource_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    FdResource *res = (FdResource *)obj;
    if (!res->closed && res->fd >= 0) {
        close(res->fd);
    }
}

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, reason));
}

static ERL_NIF_TERM make_posix_error(ErlNifEnv *env, int err) {
    switch (err) {
        case ENOENT: return make_error(env, "enoent");
        case EACCES: return make_error(env, "eacces");
        case EWOULDBLOCK: return make_error(env, "would_block");
#if EAGAIN != EWOULDBLOCK
        case EAGAIN: return make_error(env, "would_block");
#endif
        case EINTR: return make_error(env, "eintr");
        default: return make_error(env, "unknown");
    }
}

/* nif_open(Path, Mode) -> {:ok, ref} | {:error, reason} */
/* Mode: :read | :write */
static ERL_NIF_TERM nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    char path[4096];
    char mode_str[16];

    if (!enif_get_string(env, argv[0], path, sizeof(path), ERL_NIF_LATIN1))
        return make_error(env, "badarg");
    if (!enif_get_atom(env, argv[1], mode_str, sizeof(mode_str), ERL_NIF_LATIN1))
        return make_error(env, "badarg");

    int flags;
    if (strcmp(mode_str, "read") == 0)
        flags = O_RDONLY;
    else if (strcmp(mode_str, "write") == 0)
        flags = O_RDWR;
    else
        return make_error(env, "badarg");

    int fd = open(path, flags);
    if (fd < 0)
        return make_posix_error(env, errno);

    FdResource *res = enif_alloc_resource(FD_RESOURCE, sizeof(FdResource));
    res->fd = fd;
    res->closed = 0;

    ERL_NIF_TERM ref = enif_make_resource(env, res);
    enif_release_resource(res);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), ref);
}

/* nif_flock(Ref, Operation) -> :ok | {:error, reason} */
/* Operation: :exclusive | :shared */
static ERL_NIF_TERM nif_flock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    FdResource *res;
    char op_str[16];

    if (!enif_get_resource(env, argv[0], FD_RESOURCE, (void **)&res))
        return make_error(env, "badarg");
    if (res->closed)
        return make_error(env, "closed");
    if (!enif_get_atom(env, argv[1], op_str, sizeof(op_str), ERL_NIF_LATIN1))
        return make_error(env, "badarg");

    int operation;
    if (strcmp(op_str, "exclusive") == 0)
        operation = LOCK_EX | LOCK_NB;
    else if (strcmp(op_str, "shared") == 0)
        operation = LOCK_SH | LOCK_NB;
    else
        return make_error(env, "badarg");

    if (flock(res->fd, operation) < 0)
        return make_posix_error(env, errno);

    return enif_make_atom(env, "ok");
}

/* nif_close(Ref) -> :ok */
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    FdResource *res;

    if (!enif_get_resource(env, argv[0], FD_RESOURCE, (void **)&res))
        return make_error(env, "badarg");

    if (!res->closed) {
        close(res->fd);
        res->closed = 1;
    }

    return enif_make_atom(env, "ok");
}

static int on_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;
    FD_RESOURCE = enif_open_resource_type(env, NULL, "flock_fd",
        fd_resource_dtor, ERL_NIF_RT_CREATE, NULL);
    if (!FD_RESOURCE) return -1;
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"nif_open", 2, nif_open, 0},
    {"nif_flock", 2, nif_flock, 0},
    {"nif_close", 1, nif_close, 0},
};

ERL_NIF_INIT(Elixir.Commonplace.Flock, nif_funcs, on_load, NULL, NULL, NULL)
