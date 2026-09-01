`timescale 1ns / 1ps
module com_shift_reg
#(
	parameter DEPTH=30,
	parameter WIDTH=8,
	parameter SRL_STYLE_VAL="reg_srl_reg"
)
(
	input clk,
	input rst,
	input [WIDTH-1:0] si,
	output [WIDTH-1:0] so
);
	genvar i;
	generate
		if (DEPTH == 0) begin : g_passthrough
			// A continuous assignment avoids the time-zero race between the
			// old procedural head assignment and memory initialization.  Tags
			// often remain constant for an entire context, so waiting for an
			// input transition is not a valid zero-delay implementation.
			assign so = si;
		end else begin : g_pipeline
			(* srl_style=SRL_STYLE_VAL*)
			reg [WIDTH-1:0] sreg [0:DEPTH-1];
			integer t;
			initial begin
				for (t = 0; t < DEPTH; t = t + 1)
					sreg[t] = {WIDTH{1'b0}};
			end
			always @(posedge clk) begin
				if (rst)
					sreg[0] <= {WIDTH{1'b0}};
				else
					sreg[0] <= si;
			end
			for (i = 1; i < DEPTH; i = i + 1) begin : g_shift
				always @(posedge clk) begin
					if (rst)
						sreg[i] <= {WIDTH{1'b0}};
					else
						sreg[i] <= sreg[i-1];
				end
			end
			assign so = sreg[DEPTH-1];
		end
	endgenerate
endmodule
