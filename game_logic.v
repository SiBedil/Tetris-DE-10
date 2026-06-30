// ============================================================================
// Game Logic FSM & Rendering Engine
// ============================================================================
module game_logic (
    input wire clk,            // System clock (50MHz)
    input wire reset,
    input wire move_left,      
    input wire move_right,     
    input wire rotate,         
    input wire drop,           
    input wire [9:0] x_pos,    
    input wire [9:0] y_pos,    
    input wire video_on,       
    
    output reg [7:0] vga_r,    
    output reg [7:0] vga_g,    
    output reg [7:0] vga_b     
);

    // --- 1. BOARD CONSTANTS ---
    // 10x20 grid, 16x16 pixels per block (Allows clean >> 4 division in hardware)
    parameter BOARD_X_START = 240; 
    parameter BOARD_X_END   = 400; // 240 + (10 * 16)
    parameter BOARD_Y_START = 80;
    parameter BOARD_Y_END   = 400; // 80 + (20 * 16)

    wire is_board_area = (x_pos >= BOARD_X_START && x_pos < BOARD_X_END && 
                          y_pos >= BOARD_Y_START && y_pos < BOARD_Y_END);

    // --- 2. MEMORY & REGISTERS ---
    // 20 rows, 10 cols, 1-bit boolean flag (0 = empty, 1 = filled)
    // Reducing to 1-bit memory massively saves logic components
    reg board [0:19][0:9]; 
    
    localparam INIT       = 3'd0;
    localparam SPAWN      = 3'd1;
    localparam ACTIVE     = 3'd2;
    localparam LOCK       = 3'd3;
    localparam CHECK_ROW  = 3'd4;
    localparam SHIFT_ROW  = 3'd5;
    localparam GAME_OVER  = 3'd6;
    
    reg [2:0] state = INIT;
    
    // Increased coordinate depth to signed 6-bit to prevent negative wrap-around bugs at the 20 boundary
    reg signed [5:0] piece_x;   
    reg signed [5:0] piece_y;   
    reg [2:0] piece_type;       // 0 to 6
    reg [1:0] piece_rot;        // 0 to 3
    
    reg [2:0] next_type = 0;    // Tracks the piece in the preview box
    
    reg signed [5:0] check_y;   // Used for scanning lines
    reg signed [5:0] shift_y;   // Used for shifting lines down

    // --- 3. TIMING & DEBOUNCE ---
    reg [19:0] debounce_cnt;
    wire debounce_tick = (debounce_cnt == 1_000_000); // 50Hz Polling
    
    reg left_prev, right_prev, rot_prev;
    reg move_left_edge, move_right_edge, rotate_edge;

    // Game tick (Gravity) - drops faster if 'drop' is held
    reg [24:0] tick_counter = 0;
    wire [24:0] tick_max = drop ? 25_000_000/10 : 25_000_000; // Normal vs Soft Drop
    wire game_tick = (tick_counter >= tick_max) && (state == ACTIVE);

    always @(posedge clk) begin
        // Debouncer
        if (debounce_tick) begin
            debounce_cnt <= 0;
            move_left_edge  <= move_left  & ~left_prev;
            move_right_edge <= move_right & ~right_prev;
            rotate_edge     <= rotate     & ~rot_prev;
            
            left_prev  <= move_left;
            right_prev <= move_right;
            rot_prev   <= rotate;
        end else begin
            debounce_cnt <= debounce_cnt + 1;
            // Clear edges after 1 clock cycle to ensure single-trigger FSM
            move_left_edge <= 0;
            move_right_edge <= 0;
            rotate_edge <= 0;
        end
        
        // Gravity Timer
        if (state == ACTIVE) begin
            if (game_tick) tick_counter <= 0;
            else tick_counter <= tick_counter + 1;
        end else begin
            tick_counter <= 0;
        end
    end

    // Free-running random counter for piece generation
    reg [2:0] rand_type = 0;
    always @(posedge clk) begin
        if (rand_type == 3'd6) rand_type <= 0;
        else rand_type <= rand_type + 1;
    end

    // --- 4. TETROMINO SHAPES & COLLISION ENGINE ---
    // Returns a 16-bit map representing the 4x4 grid of a piece
    function [15:0] get_shape;
        input [2:0] type;
        input [1:0] rot;
        begin
            case (type)
                3'd0: get_shape = 16'h6600; // O 
                3'd1: get_shape = (rot%2==0) ? 16'h0F00 : 16'h2222; // I 
                3'd2: get_shape = (rot%2==0) ? 16'h06C0 : 16'h4620; // S 
                3'd3: get_shape = (rot%2==0) ? 16'h0C60 : 16'h2640; // Z 
                3'd4: case(rot) 0:get_shape=16'h0E80; 1:get_shape=16'hC440; 2:get_shape=16'h2E00; 3:get_shape=16'h4460; endcase // L 
                3'd5: case(rot) 0:get_shape=16'h0E20; 1:get_shape=16'h44C0; 2:get_shape=16'h8E00; 3:get_shape=16'h6440; endcase // J 
                3'd6: case(rot) 0:get_shape=16'h0E40; 1:get_shape=16'h4C40; 2:get_shape=16'h4E00; 3:get_shape=16'h4640; endcase // T 
                default: get_shape = 16'h0000;
            endcase
        end
    endfunction

    // Safe Combinational Collision Check
    function is_collision;
        input integer test_x;
        input integer test_y;
        input [1:0] test_rot;
        input [2:0] test_type;
        integer i, px, py;
        reg [15:0] shape;
        begin
            is_collision = 0;
            shape = get_shape(test_type, test_rot);
            for (i=0; i<16; i=i+1) begin
                if (shape[15-i]) begin
                    px = test_x + (i % 4);
                    py = test_y + (i / 4);
                    
                    if (px < 0 || px >= 10 || py >= 20) begin
                        is_collision = 1; // Wall or floor hit
                    end else if (py >= 0 && px >= 0 && px < 10) begin
                        // Enclosed strict bounds checking to stop the memory array from crashing on edges
                        if (board[py][px] != 1'b0) begin
                            is_collision = 1; // Placed block hit
                        end
                    end
                end
            end
        end
    endfunction

    wire [15:0] current_shape = get_shape(piece_type, piece_rot);

    // --- 5. THE MAIN GAME FSM ---
    integer row, col;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= INIT;
        end else begin
            case (state)
                INIT: begin
                    // Clear the entire board
                    for (row = 0; row < 20; row = row + 1) begin
                        for (col = 0; col < 10; col = col + 1) begin
                            board[row][col] <= 1'b0;
                        end
                    end
                    next_type <= rand_type;
                    state <= SPAWN;
                end
                
                SPAWN: begin
                    piece_type <= next_type;
                    next_type <= rand_type;
                    piece_rot <= 2'd0;
                    piece_x <= 6'd3; // Spawn in middle
                    piece_y <= 6'd0;
                    
                    if (is_collision(3, 0, 0, next_type)) begin
                        state <= GAME_OVER;
                    end else begin
                        state <= ACTIVE;
                    end
                end
                
                ACTIVE: begin
                    if (game_tick) begin
                        if (is_collision(piece_x, piece_y + 1, piece_rot, piece_type)) begin
                            state <= LOCK;
                        end else begin
                            piece_y <= piece_y + 1;
                        end
                    end else if (move_left_edge) begin
                        if (!is_collision(piece_x - 1, piece_y, piece_rot, piece_type))
                            piece_x <= piece_x - 1;
                    end else if (move_right_edge) begin
                        if (!is_collision(piece_x + 1, piece_y, piece_rot, piece_type))
                            piece_x <= piece_x + 1;
                    end else if (rotate_edge) begin
                        if (!is_collision(piece_x, piece_y, piece_rot + 1, piece_type))
                            piece_rot <= piece_rot + 1;
                    end
                end
                
                LOCK: begin
                    // Write current piece into the board memory
                    for (row = 0; row < 16; row = row + 1) begin
                        if (current_shape[15-row]) begin
                            if ((piece_y + (row/4)) >= 0 && (piece_y + (row/4)) < 20 &&
                                (piece_x + (row%4)) >= 0 && (piece_x + (row%4)) < 10) begin
                                board[piece_y + (row/4)][piece_x + (row%4)] <= 1'b1;
                            end
                        end
                    end
                    check_y <= 19; // Start scanning from bottom
                    state <= CHECK_ROW;
                end
                
                CHECK_ROW: begin
                    if (check_y < 0) begin 
                        state <= SPAWN;
                    end else begin
                        // Check if row check_y is full
                        if (board[check_y][0] && board[check_y][1] &&
                            board[check_y][2] && board[check_y][3] &&
                            board[check_y][4] && board[check_y][5] &&
                            board[check_y][6] && board[check_y][7] &&
                            board[check_y][8] && board[check_y][9]) begin
                            
                            shift_y <= check_y;
                            state <= SHIFT_ROW;
                        end else begin
                            check_y <= check_y - 1; // Move up one row
                        end
                    end
                end
                
                SHIFT_ROW: begin
                    if (shift_y > 0) begin
                        // Shift row above into current row
                        for (col = 0; col < 10; col = col + 1) begin
                            board[shift_y][col] <= board[shift_y - 1][col];
                        end
                        shift_y <= shift_y - 1;
                    end else begin
                        // Clear the very top row
                        for (col = 0; col < 10; col = col + 1) begin
                            board[0][col] <= 1'b0;
                        end
                        // Stay in CHECK_ROW but don't decrement check_y, 
                        // to re-evaluate the row that just dropped into this slot!
                        state <= CHECK_ROW; 
                    end
                end
                
                GAME_OVER: begin
                    // Hang here until hardware reset
                    state <= GAME_OVER;
                end
                
                default: state <= INIT;
            endcase
        end
    end

    // --- 6. VGA RENDERING (COMBINATIONAL) ---
    wire [9:0] board_px = x_pos - BOARD_X_START;
    wire [9:0] board_py = y_pos - BOARD_Y_START;
    wire [3:0] grid_x = board_px >> 4; // Fast divide by 16
    wire [4:0] grid_y = board_py >> 4;
    
    // Pixel relative to the falling piece
    wire signed [5:0] rel_x = grid_x - piece_x;
    wire signed [5:0] rel_y = grid_y - piece_y;
    wire in_active_piece = (state == ACTIVE) && (rel_x >= 0 && rel_x < 4) && (rel_y >= 0 && rel_y < 4);
    wire active_pixel = in_active_piece ? current_shape[15 - (rel_y * 4 + rel_x)] : 1'b0;
    
    wire is_grid_line = (board_px[3:0] == 0) || (board_py[3:0] == 0);
    wire bg_pixel = board[grid_y][grid_x];

    // Next piece UI rendering Logic
    wire is_next_box = (x_pos >= 600 && x_pos < 620 && y_pos >= 40 && y_pos < 60);
    wire [2:0] next_grid_x = (x_pos - 600) / 5; // Divide 20px box into 5px chunks
    wire [2:0] next_grid_y = (y_pos - 40) / 5;
    wire [15:0] next_shape_map = get_shape(next_type, 2'd0);
    wire next_active = is_next_box ? next_shape_map[15 - (next_grid_y * 4 + next_grid_x)] : 1'b0;

    always @(*) begin
        if (~video_on) begin
            {vga_r, vga_g, vga_b} = 24'h000000;
        end else if (is_board_area) begin
            if (active_pixel || bg_pixel) begin
                {vga_r, vga_g, vga_b} = is_grid_line ? 24'hAA0000 : 24'hFF0000; // Solid Red blocks (darker on grid lines)
            end else begin
                {vga_r, vga_g, vga_b} = 24'h222222; // Empty space (Dark Grey)
            end
        end else if (is_next_box) begin
            if (next_active) begin
                {vga_r, vga_g, vga_b} = 24'hFF0000; // Red next piece
            end else begin
                {vga_r, vga_g, vga_b} = 24'h222222; // Next box background
            end
        end else begin
            // Red background on game over, Pitch Black otherwise to prevent eye strain
            {vga_r, vga_g, vga_b} = (state == GAME_OVER) ? 24'h880000 : 24'h000000;
        end
    end

endmodule
