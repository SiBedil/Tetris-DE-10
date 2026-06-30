module vga_controller (
    input wire clk_25MHz,     
    input wire reset,         
    output reg hsync,         
    output reg vsync,         
    output wire [9:0] x_pos,  
    output wire [9:0] y_pos,  
    output wire video_on      
);

    parameter H_DISPLAY = 640, H_FRONT = 16, H_SYNC = 96, H_BACK = 48, H_TOTAL = 800;
    parameter V_DISPLAY = 480, V_FRONT = 10, V_SYNC = 2,  V_BACK = 33, V_TOTAL = 525;

    reg [9:0] h_count = 0;
    reg [9:0] v_count = 0;

    always @(posedge clk_25MHz or posedge reset) begin
        if (reset) begin
            h_count <= 0;
            v_count <= 0;
        end else begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= 0;
                if (v_count == V_TOTAL - 1)
                    v_count <= 0;
                else
                    v_count <= v_count + 1;
            end else begin
                h_count <= h_count + 1;
            end
        end
    end

    always @(posedge clk_25MHz) begin
        hsync <= ~((h_count >= H_DISPLAY + H_FRONT) && (h_count < H_DISPLAY + H_FRONT + H_SYNC));
        vsync <= ~((v_count >= V_DISPLAY + V_FRONT) && (v_count < V_DISPLAY + V_FRONT + V_SYNC));
    end

    assign x_pos = h_count;
    assign y_pos = v_count;
    assign video_on = (h_count < H_DISPLAY) && (v_count < V_DISPLAY);

endmodule