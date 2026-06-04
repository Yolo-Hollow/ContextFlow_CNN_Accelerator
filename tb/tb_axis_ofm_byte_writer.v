`timescale 1ns / 1ps

module tb_axis_ofm_byte_writer;
    localparam OFM_ADDR_W = 24;

    reg [OFM_ADDR_W-1:0] byte_addr;
    reg [7:0] byte_data;
    reg byte_valid;
    wire byte_ready;
    reg byte_last;
    wire [63:0] m_axis_tdata;
    wire [7:0] m_axis_tkeep;
    wire m_axis_tvalid;
    reg m_axis_tready;
    wire m_axis_tlast;

    integer pass;
    integer fail;

    axis_ofm_byte_writer #(.OFM_ADDR_W(OFM_ADDR_W)) dut (
        .byte_addr(byte_addr),
        .byte_data(byte_data),
        .byte_valid(byte_valid),
        .byte_ready(byte_ready),
        .byte_last(byte_last),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (cond) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("[FAIL] %0s", msg);
            end
        end
    endtask

    initial begin
        pass = 0;
        fail = 0;
        byte_addr = 24'h12_3456;
        byte_data = 8'ha5;
        byte_valid = 1'b0;
        byte_last = 1'b0;
        m_axis_tready = 1'b0;

        #1;
        check(!byte_ready, "byte ready follows low AXIS ready");
        check(!m_axis_tvalid, "AXIS valid follows low byte valid");
        check(m_axis_tkeep == 8'hff, "AXIS keep marks full 64-bit beat");

        byte_valid = 1'b1;
        byte_last = 1'b1;
        #1;
        check(m_axis_tvalid, "AXIS valid follows byte valid");
        check(!byte_ready, "byte ready remains low under backpressure");
        check(m_axis_tdata[23:0] == 24'h12_3456, "AXIS packs OFM address");
        check(m_axis_tdata[31:24] == 8'ha5, "AXIS packs OFM data byte");
        check(m_axis_tdata[63:32] == 32'd0, "AXIS upper bits are zero");
        check(m_axis_tlast, "AXIS TLAST passes through");

        m_axis_tready = 1'b1;
        #1;
        check(byte_ready, "byte ready follows high AXIS ready");

        byte_last = 1'b0;
        #1;
        check(!m_axis_tlast, "AXIS TLAST clears with byte last");

        $display("=== %m: %0d pass, %0d fail ===", pass, fail);
        if (fail != 0) $fatal(1);
        $finish;
    end
endmodule
