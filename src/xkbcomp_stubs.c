/* Stubs for the X11-client symbols xkbcomp references only on its display
 * input/output code paths (xkbcomp <display> ...). We compile xkbcomp as an
 * in-process library that only ever does file->file .xkm compilation, so these
 * are never reached; defining them here lets us avoid dragging in libX11.
 *
 * They are combined (ld -r) with the xkbcomp objects and then localized
 * (objcopy --keep-global-symbol=unpin_xkbcomp_main), so they become file-local
 * symbols inside the xkbcomp blob and never clash with libxkbfile / the server.
 */
typedef struct _XDisplay Display;

void *XkbOpenDisplay(const char *a, int *b, int *c, int *d, int *e, int *f)
{
    (void) a; (void) b; (void) c; (void) d; (void) e; (void) f;
    return (void *) 0;
}

int XSynchronize(Display *dpy, int onoff)
{
    (void) dpy; (void) onoff;
    return 0;
}

int XCloseDisplay(Display *dpy)
{
    (void) dpy;
    return 0;
}

/* libxkbfile display writers, unused on our path. Return values are ignored
 * (the calls are guarded by inDpy/outDpy == NULL, which never holds here). */
int XkbChangeKbdDisplay(Display *dpy, void *result)
{
    (void) dpy; (void) result;
    return 0;
}

int XkbWriteToServer(void *result)
{
    (void) result;
    return 0;
}

/* Display-read client calls (xkbcomp <display> input). Never reached in-process
 * -- we only ever compile file->file -- but referenced in compiled code, so
 * define them here to keep libX11's display/transport stack out of the link. */
void *XkbGetMap(Display *d, unsigned w, unsigned dev) { (void)d;(void)w;(void)dev; return (void*)0; }
int XkbGetControls(Display *d, unsigned long w, void *x) { (void)d;(void)w;(void)x; return 0; }
int XkbGetGeometry(Display *d, void *x) { (void)d;(void)x; return 0; }
int XkbGetNames(Display *d, unsigned w, void *x) { (void)d;(void)w;(void)x; return 0; }
int XkbGetIndicatorMap(Display *d, unsigned long w, void *x) { (void)d;(void)w;(void)x; return 0; }
int XkbGetCompatMap(Display *d, unsigned w, void *x) { (void)d;(void)w;(void)x; return 0; }
int XGetErrorText(Display *d, int c, char *b, int n) { (void)d;(void)c; if(n>0)b[0]='\0'; return 0; }

/* Called by main() on the file path to gate XKB lib ABI; report compatible. */
int XkbLibraryVersion(int *libMajor, int *libMinor) { (void)libMajor;(void)libMinor; return 1; }

/* The only display leaves the extracted libxkbfile/libX11 .o reach: libxkbfile's
 * xkbatom.o XkbInternAtom/XkbAtomGetString call these in their dpy!=NULL branch,
 * which is dead in-process (we always pass dpy=NULL, taking the internal atom
 * table). Defining them here keeps libX11's IntAtom.o + the whole display/xcb
 * transport out of the link. */
typedef unsigned long Atom;
Atom XInternAtom(Display *d, const char *n, int e) { (void)d;(void)n;(void)e; return 0; }
char *XGetAtomName(Display *d, Atom a) { (void)d;(void)a; return (char*)0; }
