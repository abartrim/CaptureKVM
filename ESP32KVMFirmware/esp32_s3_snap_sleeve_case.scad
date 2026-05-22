// ESP32-S3 Dual USB-C Snap-Fit Sleeve Case
// Parametric OpenSCAD model
//
// Coordinate system:
//   X = board length / slide direction
//   Y = board width
//   Z = case height
//
// The board slides into the sleeve from +X.
// The closed end is at X = 0.
// The removable USB-C end cap is at +X.

$fn = 32;

// -----------------------------------------------------------------------------
// Preview toggles
// -----------------------------------------------------------------------------
show_case        = true;
show_cap         = true;
show_board_dummy = true;
exploded_preview = true;

// -----------------------------------------------------------------------------
// Board envelope
// -----------------------------------------------------------------------------
board_len    = 57.0;
board_w      = 28.0;
board_h      = 10.0;

board_clear_x = 2.0;     // total length clearance
board_clear_y = 2.0;     // total width clearance
board_clear_z = 2.0;     // total height clearance

inner_len = board_len + board_clear_x;  // 59
inner_w   = board_w   + board_clear_y;  // 30
inner_h   = board_h   + board_clear_z;  // 12

// -----------------------------------------------------------------------------
// Sleeve body parameters
// -----------------------------------------------------------------------------
wall     = 2.0;
body_r   = 1.2;
case_len = wall + inner_len;       // closed wall + cavity
outer_w  = inner_w + 2*wall;
outer_h  = inner_h + 2*wall;

eps = 0.05;

// -----------------------------------------------------------------------------
// End cap parameters
// -----------------------------------------------------------------------------
cap_plate_t = 2.0;
insert_len  = 5.0;
cap_clear   = 0.30;    // clearance per mating side target; total clearance = 2*cap_clear
cap_r       = body_r;

insert_w = inner_w - 2*cap_clear;
insert_h = inner_h - 2*cap_clear;

// USB-C cutouts in cap
usb_cut_y       = 9.5;
usb_cut_z       = 5.5;
usb_spacing_y   = 14.4;
usb_center_z    = wall + 5.7;
usb_cut_depth_x = cap_plate_t + insert_len + 1.0;

// Snap bead and sleeve catch geometry
snap_x_from_open = 5.1;   // catch center measured inward from open end of sleeve
snap_len_x       = 1.4;
snap_w_y         = 18.0;
snap_h           = 0.45;

bead_len_x       = 3.0;
bead_w_y         = 16.0;
bead_h           = snap_h;
bead_x_from_face = 3.6;

// -----------------------------------------------------------------------------
// Helper modules
// -----------------------------------------------------------------------------
module rounded_box(size=[10,10,10], r=1) {
    // Exact-size rounded cuboid using hull of spheres.
    // Avoid r larger than half the smallest dimension.
    hull() {
        for (x=[r, size[0]-r])
        for (y=[r, size[1]-r])
        for (z=[r, size[2]-r])
            translate([x,y,z]) sphere(r=r);
    }
}

module board_dummy() {
    // Visual placeholder only. Do not export this part for printing.
    color([0.1, 0.45, 0.15, 0.35])
    translate([wall + board_clear_x/2, wall + board_clear_y/2, wall + board_clear_z/2])
        cube([board_len, board_w, board_h]);

    // Approximate USB-C connector blocks at +X end for visual alignment.
    for (yc=[outer_w/2 - usb_spacing_y/2, outer_w/2 + usb_spacing_y/2]) {
        color([0.75, 0.75, 0.78, 0.7])
        translate([case_len - 2.5, yc - 4.0, usb_center_z - 2.0])
            cube([4.0, 8.0, 4.0]);
    }
}

// Ramped bead as a triangular prism running along Y.
// The triangular profile ramps in X and protrudes in Z.
module ramp_bead(len_x=3, width_y=16, height_z=0.45, flip_z=false) {
    if (!flip_z) {
        polyhedron(
            points=[
                [0,       0,       0],
                [len_x,   0,       0],
                [len_x,   0,       height_z],
                [0,       width_y, 0],
                [len_x,   width_y, 0],
                [len_x,   width_y, height_z]
            ],
            faces=[
                [0,1,2], [3,5,4],
                [0,3,4], [0,4,1],
                [1,4,5], [1,5,2],
                [2,5,3], [2,3,0]
            ]
        );
    } else {
        mirror([0,0,1])
        polyhedron(
            points=[
                [0,       0,       0],
                [len_x,   0,       0],
                [len_x,   0,       height_z],
                [0,       width_y, 0],
                [len_x,   width_y, 0],
                [len_x,   width_y, height_z]
            ],
            faces=[
                [0,1,2], [3,5,4],
                [0,3,4], [0,4,1],
                [1,4,5], [1,5,2],
                [2,5,3], [2,3,0]
            ]
        );
    }
}

// -----------------------------------------------------------------------------
// Main sleeve body
// -----------------------------------------------------------------------------
module sleeve_body() {
    difference() {
        // Rounded outer electronics enclosure sleeve.
        rounded_box([case_len, outer_w, outer_h], body_r);

        // Hollow interior cavity. It starts after the closed end wall and extends
        // slightly beyond the open end so the USB-C side is genuinely open.
        translate([wall, wall, wall])
            cube([inner_len + eps, inner_w, inner_h]);

        // Top internal catch pocket for cap snap bead.
        translate([case_len - snap_x_from_open - snap_len_x/2,
                   outer_w/2 - snap_w_y/2,
                   wall + inner_h - snap_h + eps])
            cube([snap_len_x, snap_w_y, snap_h + eps]);

        // Bottom internal catch pocket for cap snap bead.
        translate([case_len - snap_x_from_open - snap_len_x/2,
                   outer_w/2 - snap_w_y/2,
                   wall - eps])
            cube([snap_len_x, snap_w_y, snap_h + eps]);
    }
}

// -----------------------------------------------------------------------------
// Snap-on USB-C end cap
// -----------------------------------------------------------------------------
module usb_c_end_cap() {
    difference() {
        union() {
            // Visible rounded end face. In final assembly this sits just beyond
            // the sleeve's open end.
            rounded_box([cap_plate_t, outer_w, outer_h], cap_r);

            // Internal plug/tongue. This inserts into the hollow sleeve and centers
            // the cap. It is deliberately smaller than the sleeve cavity.
            translate([cap_plate_t - eps,
                       wall + cap_clear,
                       wall + cap_clear])
                cube([insert_len, insert_w, insert_h]);

            // Top snap bead on insert tongue.
            translate([cap_plate_t + bead_x_from_face,
                       outer_w/2 - bead_w_y/2,
                       wall + cap_clear + insert_h])
                ramp_bead(bead_len_x, bead_w_y, bead_h, false);

            // Bottom snap bead on insert tongue.
            translate([cap_plate_t + bead_x_from_face,
                       outer_w/2 - bead_w_y/2,
                       wall + cap_clear])
                ramp_bead(bead_len_x, bead_w_y, bead_h, true);
        }

        // Two USB-C openings through the cap face. They are intentionally generous.
        for (yc=[outer_w/2 - usb_spacing_y/2, outer_w/2 + usb_spacing_y/2]) {
            translate([-eps,
                       yc - usb_cut_y/2,
                       usb_center_z - usb_cut_z/2])
                cube([usb_cut_depth_x, usb_cut_y, usb_cut_z]);
        }
    }
}

// -----------------------------------------------------------------------------
// Preview assembly
// -----------------------------------------------------------------------------
if (show_case) {
    color([0.82,0.82,0.78,1.0]) sleeve_body();
}

if (show_board_dummy) {
    board_dummy();
}

if (show_cap) {
    cap_offset = exploded_preview ? 8 : 0;
    color([0.72,0.72,0.68,1.0])
    translate([case_len + cap_offset, 0, 0])
        usb_c_end_cap();
}

// -----------------------------------------------------------------------------
// Export instructions:
//   1. To export the sleeve only, comment out the preview section and call:
//        sleeve_body();
//   2. To export the cap only, call:
//        usb_c_end_cap();
//   3. Keep board_dummy() disabled for STL export.
// -----------------------------------------------------------------------------
