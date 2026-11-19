// Stage-0.2 fixed-point contract used by Stage-2.
localparam integer PIXEL_W = 16;
localparam integer PIXEL_FRAC = 11;       // signed Q5.11
localparam integer FWHT_W = 32;
localparam integer FWHT_FRAC = 11;        // signed S32.F11
localparam integer FWHT_NORM_SHIFT = 6;   // H_4096 / 64
localparam integer MEASURE_COUNT = 1024;
localparam integer FISTA_OUTER_ITERS = 40;
localparam integer TV_INNER_ITERS = 35;
