// Stage-0.2 proposed numeric contract; include inside a module if needed.
localparam integer PIXEL_W = 16;
localparam integer PIXEL_FRAC = 11; // signed Q5.11
localparam integer FWHT_W = 32;
localparam integer FWHT_FRAC = 11;
localparam integer FWHT_NORM_SHIFT = 6; // H_4096 / 64
localparam integer TV_DIV_W = 18;
localparam integer TV_LAMBDA_Q11 = 20; // 20/2048
localparam integer FISTA_BETA_FRAC = 15;
localparam integer FISTA_OUTER_ITERS = 40;
localparam integer TV_INNER_ITERS = 35;
