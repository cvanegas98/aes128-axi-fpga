// shiftrows testbench. reads vectors/roundstep.txt and checks the shiftrows
// column for every state.
//
// gui: set tb_shiftrows as sim top and Run Simulation. or from the repo root:
//   xvlog -sv rtl/shiftrows.sv tb/tb_shiftrows.sv
//   xelab tb_shiftrows -s tb_shiftrows_sim
//   xsim tb_shiftrows_sim -R

`timescale 1ns / 1ps

module tb_shiftrows;

    logic [127:0] state_in, state_out;
    logic [127:0] vec_state, exp_sb, exp_sr, exp_mc;
    int fd, n = 0, errors = 0;

    shiftrows dut (
        .state_in  (state_in),
        .state_out (state_out)
    );

    initial begin
        fd = $fopen("vectors/roundstep.txt", "r");
        if (fd == 0) fd = $fopen("roundstep.txt", "r");
        if (fd == 0) begin
            $display("FAIL: can't open roundstep.txt");
            $finish;
        end

        while ($fscanf(fd, "%h %h %h %h", vec_state, exp_sb, exp_sr, exp_mc) == 4) begin
            state_in = vec_state;
            #1;
            if (state_out !== exp_sr) begin
                $display("FAIL: shiftrows(%032x) = %032x, expected %032x",
                         vec_state, state_out, exp_sr);
                errors++;
            end
            n++;
        end
        $fclose(fd);

        if (errors == 0)
            $display("PASS: shiftrows matches the model on all %0d states", n);
        else
            $display("FAIL: %0d mismatches out of %0d", errors, n);
        $finish;
    end

endmodule
