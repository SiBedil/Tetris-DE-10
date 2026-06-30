// ============================================================================
// FPGA VGA Tetris Game - Top Level Module
// Designed for DE10-Standard (50MHz Clock)
// ============================================================================

module tetris_top (
    input wire CLOCK_50,       // 50 MHz DE10 Clock
    input wire [3:0] KEY,      // Active-low push buttons
    input wire [9:0] SW,       // Slide switches

    // VGA Outputs
    output wire [7:0] VGA_R,
    output wire [7:0] VGA_G,
    output wire [7:0] VGA_B,
    output wire VGA_HS,
    output wire VGA_VS,
    output wire VGA_CLK,
    output wire VGA_SYNC_N,
    output wire VGA_BLANK_N
);

    // --- 1. Clock Divider (50MHz to 25MHz for VGA) ---
    reg clk_25MHz = 0;
    always @(posedge CLOCK_50) begin
        clk_25MHz <= ~clk_25MHz;
    end
    
    assign VGA_CLK = clk_25MHz;
    assign VGA_SYNC_N = 1'b0; // Required for ADV7123 DAC

    // --- 2. Interconnects ---
    wire [9:0] w_x_pos, w_y_pos;
    wire w_video_on;
    wire w_reset = SW[0];     // Use Switch 0 for Reset

    // --- 3. VGA Controller ---
    vga_controller vga_inst (
        .clk_25MHz(clk_25MHz),
        .reset(w_reset),
        .hsync(VGA_HS),
        .vsync(VGA_VS),
        .x_pos(w_x_pos),
        .y_pos(w_y_pos),
        .video_on(w_video_on)
    );
    
    // Blanking must follow video_on for the DAC
    assign VGA_BLANK_N = w_video_on;

    // --- 4. Game Logic ---
    game_logic game_inst (
        .clk(CLOCK_50),
        .reset(w_reset),
        
        // DE10 Keys are active-low, invert them here
        .move_left(~KEY[3]),   
        .rotate(~KEY[2]),      
        .move_right(~KEY[1]),  
        .drop(~KEY[0]),        
        
        .x_pos(w_x_pos),
        .y_pos(w_y_pos),
        .video_on(w_video_on),
        
        .vga_r(VGA_R),
        .vga_g(VGA_G),
        .vga_b(VGA_B)
    );

endmodule
