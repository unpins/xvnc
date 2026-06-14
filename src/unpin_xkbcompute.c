/* Three pure (display-free) XKB compute helpers that xkbcomp needs but which
 * live in libX11 .o that also drag the Xlib protocol/display stack (XKB.o,
 * XKBGeom.o). Vendored here against the PUBLIC xorgproto headers so the blob
 * stays self-contained. XkbVirtualModsToReal is provided by the extracted
 * XKBMisc.o. */
#include <stddef.h>
#include <string.h>
#include <X11/Xlib.h>                       /* Display, Bool, Status, Atom, True/False */
#include <X11/extensions/XKBstr.h>
#include <X11/extensions/XKBgeom.h>

#ifndef MAXSHORT
#define MAXSHORT 32767
#define MINSHORT (-32768)
#endif

extern Bool XkbVirtualModsToReal(XkbDescPtr xkb, unsigned virtual_mask,
                                 unsigned *mask_rtrn);

Bool
XkbComputeEffectiveMap(XkbDescPtr xkb,
                       XkbKeyTypePtr type,
                       unsigned char *map_rtrn)
{
    register int i;
    unsigned tmp;
    XkbKTMapEntryPtr entry = NULL;

    if ((!xkb) || (!type) || (!xkb->server))
        return False;

    if (type->mods.vmods != 0) {
        if (!XkbVirtualModsToReal(xkb, type->mods.vmods, &tmp))
            return False;

        type->mods.mask = tmp | type->mods.real_mods;
        entry = type->map;
        for (i = 0; i < type->map_count; i++, entry++) {
            tmp = 0;
            if (entry->mods.vmods != 0) {
                if (!XkbVirtualModsToReal(xkb, entry->mods.vmods, &tmp))
                    return False;
                if (tmp == 0) {
                    entry->active = False;
                    continue;
                }
            }
            entry->active = True;
            entry->mods.mask = (entry->mods.real_mods | tmp) & type->mods.mask;
        }
    }
    else {
        type->mods.mask = type->mods.real_mods;
    }
    if (map_rtrn != NULL) {
        bzero(map_rtrn, type->mods.mask + 1);
        for (i = 0; i < type->map_count; i++) {
            if (entry && entry->active) {
                map_rtrn[type->map[i].mods.mask] = type->map[i].level;
            }
        }
    }
    return True;
}

/***====================================================================***/

static void
_XkbCheckBounds(XkbBoundsPtr bounds, int x, int y)
{
    if (x < bounds->x1)
        bounds->x1 = x;
    if (x > bounds->x2)
        bounds->x2 = x;
    if (y < bounds->y1)
        bounds->y1 = y;
    if (y > bounds->y2)
        bounds->y2 = y;
    return;
}

Bool
XkbComputeShapeBounds(XkbShapePtr shape)
{
    register int o, p;
    XkbOutlinePtr outline;
    XkbPointPtr pt;

    if ((!shape) || (shape->num_outlines < 1))
        return False;
    shape->bounds.x1 = shape->bounds.y1 = MAXSHORT;
    shape->bounds.x2 = shape->bounds.y2 = MINSHORT;
    for (outline = shape->outlines, o = 0; o < shape->num_outlines;
         o++, outline++) {
        for (pt = outline->points, p = 0; p < outline->num_points; p++, pt++) {
            _XkbCheckBounds(&shape->bounds, pt->x, pt->y);
        }
        if (outline->num_points < 2) {
            _XkbCheckBounds(&shape->bounds, 0, 0);
        }
    }
    return True;
}

Bool
XkbComputeShapeTop(XkbShapePtr shape, XkbBoundsPtr bounds)
{
    register int p;
    XkbOutlinePtr outline;
    XkbPointPtr pt;

    if ((!shape) || (shape->num_outlines < 1))
        return False;
    if (shape->approx)
        outline = shape->approx;
    else
        outline = &shape->outlines[shape->num_outlines - 1];
    if (outline->num_points < 2) {
        bounds->x1 = bounds->y1 = 0;
        bounds->x2 = bounds->y2 = 0;
    }
    else {
        bounds->x1 = bounds->y1 = MAXSHORT;
        bounds->x2 = bounds->y2 = MINSHORT;
    }
    for (pt = outline->points, p = 0; p < outline->num_points; p++, pt++) {
        _XkbCheckBounds(bounds, pt->x, pt->y);
    }
    return True;
}

Bool
XkbComputeRowBounds(XkbGeometryPtr geom, XkbSectionPtr section, XkbRowPtr row)
{
    register int k, pos;
    XkbKeyPtr key;
    XkbBoundsPtr bounds, sbounds;

    if ((!geom) || (!section) || (!row))
        return False;
    bounds = &row->bounds;
    bzero(bounds, sizeof(XkbBoundsRec));
    for (key = row->keys, pos = k = 0; k < row->num_keys; k++, key++) {
        sbounds = &XkbKeyShape(geom, key)->bounds;
        _XkbCheckBounds(bounds, pos, 0);
        if (!row->vertical) {
            if (key->gap != 0) {
                pos += key->gap;
                _XkbCheckBounds(bounds, pos, 0);
            }
            _XkbCheckBounds(bounds, pos + sbounds->x1, sbounds->y1);
            _XkbCheckBounds(bounds, pos + sbounds->x2, sbounds->y2);
            pos += sbounds->x2;
        }
        else {
            if (key->gap != 0) {
                pos += key->gap;
                _XkbCheckBounds(bounds, 0, pos);
            }
            _XkbCheckBounds(bounds, pos + sbounds->x1, sbounds->y1);
            _XkbCheckBounds(bounds, pos + sbounds->x2, sbounds->y2);
            pos += sbounds->y2;
        }
    }
    return True;
}

Bool
XkbComputeSectionBounds(XkbGeometryPtr geom, XkbSectionPtr section)
{
    register int i;
    XkbShapePtr shape;
    XkbRowPtr row;
    XkbDoodadPtr doodad;
    XkbBoundsPtr bounds, rbounds;

    if ((!geom) || (!section))
        return False;
    bounds = &section->bounds;
    bzero(bounds, sizeof(XkbBoundsRec));
    for (i = 0, row = section->rows; i < section->num_rows; i++, row++) {
        if (!XkbComputeRowBounds(geom, section, row))
            return False;
        rbounds = &row->bounds;
        _XkbCheckBounds(bounds, row->left + rbounds->x1,
                        row->top + rbounds->y1);
        _XkbCheckBounds(bounds, row->left + rbounds->x2,
                        row->top + rbounds->y2);
    }
    for (i = 0, doodad = section->doodads; i < section->num_doodads;
         i++, doodad++) {
        static XkbBoundsRec tbounds;

        switch (doodad->any.type) {
        case XkbOutlineDoodad:
        case XkbSolidDoodad:
            shape = XkbShapeDoodadShape(geom, &doodad->shape);
            rbounds = &shape->bounds;
            break;
        case XkbTextDoodad:
            tbounds.x1 = doodad->text.left;
            tbounds.y1 = doodad->text.top;
            tbounds.x2 = tbounds.x1 + doodad->text.width;
            tbounds.y2 = tbounds.y1 + doodad->text.height;
            rbounds = &tbounds;
            break;
        case XkbIndicatorDoodad:
            shape = XkbIndicatorDoodadShape(geom, &doodad->indicator);
            rbounds = &shape->bounds;
            break;
        case XkbLogoDoodad:
            shape = XkbLogoDoodadShape(geom, &doodad->logo);
            rbounds = &shape->bounds;
            break;
        default:
            tbounds.x1 = tbounds.x2 = doodad->any.left;
            tbounds.y1 = tbounds.y2 = doodad->any.top;
            rbounds = &tbounds;
            break;
        }
        _XkbCheckBounds(bounds, rbounds->x1, rbounds->y1);
        _XkbCheckBounds(bounds, rbounds->x2, rbounds->y2);
    }
    return True;
}
