-- Design Name: openxenium
-- Module Name: openxenium - Behavioral
-- Project Name: OpenXenium. Open Source Xenius modchip CPLD replacement project
-- Target Devices: XC9572XL-10VQ64
--
-- Revision 0.01 - File Created - Ryan Wendland
--
-- Additional Comments:
--
-- OpenXenium is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see .
--
----------------------------------------------------------------------------------
--
--
--**BANK SELECTION**
--Bank selection is controlled by the lower nibble of address REG_00EF.
--A20,A19,A18 are address lines to the parallel flash memory.
--lines marked X means it is not forced by the CPLD for banking purposes.
--This is how is works:
--
--REGISTER 0xEF Bank Commands:
--BANK NAME                  DATA BYTE    A20|A19|A18 ADDRESS OFFSET
--TSOP                       XXXX 0000     X |X |X    N/A.     (This locks up the Xenium to force it to boot from TSOP.)
--XeniumOS(c.well loader)    XXXX 0001     1 |1 |0    0x180000 (This is the default boot state. Contains Cromwell bootloader)
--XeniumOS                   XXXX 0010     1 |0 |X    0x100000 (This is a 512kb bank and contains XeniumOS)
--BANK1 (USER BIOS 256kB)    XXXX 0011     0 |0 |0    0x000000
--BANK2 (USER BIOS 256kB)    XXXX 0100     0 |0 |1    0x040000
--BANK3 (USER BIOS 256kB)    XXXX 0101     0 |1 |0    0x080000
--BANK4 (USER BIOS 256kB)    XXXX 0110     0 |1 |1    0x0C0000
--BANK1 (USER BIOS 512kB)    XXXX 0111     0 |0 |X    0x000000
--BANK2 (USER BIOS 512kB)    XXXX 1000     0 |1 |X    0x080000
--BANK1 (USER BIOS 1MB)      XXXX 1001     0 |X |X    0x000000
--RECOVERY (NOTE 1)          XXXX 1010     1 |1 |1    0x1C0000
--
--
--NOTE 1: The RECOVERY bank can also be actived by the physical switch on the Xenium. This forces bank ten (0b1010) on power up.
--This bank also contains non-volatile storage of settings an EEPROM backup in the smaller sectors at the end of the flash memory.
--The memory map is shown below:
--     (1C0000 to 1DFFFF PROTECTED AREA 128kbyte recovery bios)
--     (1E0000 to 1FBFFF Additional XeniumOS Data)
--     (1FC000 to 1FFFFF Contains eeprom backup, XeniumOS settings)
--
--
--**XENIUM CONTROL WRITE/READ REGISTERS**
--Bits marked 'X' either have no function or an unknown function.
--**0xEF WRITE:**
--X,SCK,CS,MOSI,BANK[3:0]
--
--**0xEF READ:**
--RECOV SWITCH POSITION (0=ACTIVE),X,MISO(Pin 1),MISO (Pin 4),BANK[3:0]
--
--**0xEE (WRITE)**
--X,X,X,X X,B,G,R (DEFAULT LED ON POWER UP IS RED)
--
--**0xEE (READ)**
--Just returns 0x55 on a real xenium?
--

LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;
ENTITY openxenium IS
   PORT (
      HEADER_1 : IN STD_LOGIC;
      HEADER_4 : IN STD_LOGIC;
      HEADER_CS : OUT STD_LOGIC;
      HEADER_SCK : OUT STD_LOGIC;
      HEADER_MOSI : OUT STD_LOGIC;
      HEADER_LED_R : OUT STD_LOGIC;
      HEADER_LED_G : OUT STD_LOGIC;
      HEADER_LED_B : OUT STD_LOGIC;

      FLASH_WE : OUT STD_LOGIC;
      FLASH_OE : OUT STD_LOGIC;
      FLASH_ADDRESS : OUT STD_LOGIC_VECTOR (20 DOWNTO 0);
      FLASH_DQ : INOUT STD_LOGIC_VECTOR (7 DOWNTO 0);

      LPC_LAD : INOUT STD_LOGIC_VECTOR (3 DOWNTO 0);
      LPC_CLK : IN STD_LOGIC;
      LPC_RST : IN STD_LOGIC;

      XENIUM_RECOVERY : IN STD_LOGIC; -- Recovery is active low and requires an external Pull-up to 3.3V
      XENIUM_D0 : OUT STD_LOGIC
   );

END openxenium;

ARCHITECTURE Behavioral OF openxenium IS

   -- Optimized LPC state machine - reduced from 11 states to 4 states
   TYPE LPC_STATE_MACHINE IS (
      WAIT_START,   -- Wait for LPC start frame (0000)
      GET_CYC,      -- Get cycle type (IO/MEM, Read/Write)
      GET_ADDR,     -- Get address (8 nibbles for MEM, 4 for IO)
      DATA          -- TAR, SYNC, and DATA transfer sequences
   );

   TYPE CYC_TYPE IS (
      IO_READ,      -- Default state
      IO_WRITE,
      MEM_READ,
      MEM_WRITE
   );

   -- Constants for LPC cycle offsets
   CONSTANT C_FSM_COUNT_RESET : INTEGER := 0;
   CONSTANT C_FSM_COUNT_IO_START_OFFSET : INTEGER := 4;
   CONSTANT C_FSM_DATA_WRITE_LO_NIBBLE_OFFSET : INTEGER := 0;
   CONSTANT C_FSM_DATA_WRITE_HI_NIBBLE_OFFSET : INTEGER := 1;
   CONSTANT C_FSM_ADDR_SEQ_NIBBLE0 : INTEGER := 0;
   CONSTANT C_FSM_ADDR_SEQ_NIBBLE1 : INTEGER := 1;
   CONSTANT C_FSM_ADDR_SEQ_NIBBLE2 : INTEGER := 2;
   CONSTANT C_FSM_ADDR_SEQ_NIBBLE3 : INTEGER := 3;
   CONSTANT C_FSM_ADDR_SEQ_NIBBLE4 : INTEGER := 4;
   CONSTANT C_FSM_ADDR_SEQ_NIBBLE5 : INTEGER := 5;
   CONSTANT C_FSM_ADDR_SEQ_NIBBLE6 : INTEGER := 6;
   CONSTANT C_FSM_ADDR_SEQ_NIBBLE7 : INTEGER := 7;
   CONSTANT C_FSM_ADDR_SEQ_MAX_COUNT : INTEGER := C_FSM_ADDR_SEQ_NIBBLE7;
   CONSTANT C_FSM_DATA_SEQ_MAX_COUNT : INTEGER := 6;
   CONSTANT C_FSM_DATA_SEQ_TARA2_READ : INTEGER := 1;
   CONSTANT C_FSM_DATA_SEQ_TARA2_WRITE : INTEGER := 3;
   CONSTANT C_FSM_DATA_SEQ_DATA1_READ : INTEGER := 3;
   CONSTANT C_FSM_DATA_SEQ_DATA2_READ : INTEGER := 4;
   CONSTANT C_FSM_DATA_SEQ_SYNC_READ : INTEGER := 2;
   CONSTANT C_FSM_DATA_SEQ_SYNC_WRITE : INTEGER := 4;

   -- LPC protocol constants
   CONSTANT C_LAD_START_PATTERN : STD_LOGIC_VECTOR(3 DOWNTO 0) := "0000";
   CONSTANT C_LAD_IDLE_PATTERN : STD_LOGIC_VECTOR(3 DOWNTO 0) := "1111";
   CONSTANT C_LAD_INPUT_PATTERN : STD_LOGIC_VECTOR(3 DOWNTO 0) := "ZZZZ";
   CONSTANT C_LAD_PATTERN_SYNC : STD_LOGIC_VECTOR(3 DOWNTO 0) := "0000";
   CONSTANT C_CYC_MEM_PREFIX : STD_LOGIC_VECTOR(1 DOWNTO 0) := "01";
   CONSTANT C_CYC_IO_PREFIX : STD_LOGIC_VECTOR(1 DOWNTO 0) := "00";
   CONSTANT C_CYC_DIRECTION_READ : STD_LOGIC := '0';
   CONSTANT C_CYC_DIRECTION_WRITE : STD_LOGIC := '1';
   CONSTANT C_LAD_ADDR_PATTERN1 : STD_LOGIC_VECTOR(3 DOWNTO 0) := "1111";
   CONSTANT C_LAD_IOREG_PATTERN1 : STD_LOGIC_VECTOR(3 DOWNTO 0) := "1111";
   CONSTANT C_LAD_IOREG_PATTERN2 : STD_LOGIC_VECTOR(3 DOWNTO 0) := "0111";
   CONSTANT C_LAD_IOREG_PATTERN3 : STD_LOGIC_VECTOR(3 DOWNTO 0) := "0000";

   SIGNAL LPC_CURRENT_STATE : LPC_STATE_MACHINE := WAIT_START;
   SIGNAL CYCLE_TYPE : CYC_TYPE := IO_READ;
   SIGNAL s_lad_dir : STD_LOGIC;  -- '0' for read, '1' for write
   SIGNAL s_io_cyc : BOOLEAN := FALSE;

   SIGNAL LPC_ADDRESS : STD_LOGIC_VECTOR (20 DOWNTO 0); --LPC Address is actually 32bits for memory IO, but we only need 21.

   --XENIUM IO REGISTERS. BITS MARKED 'X' HAVE AN UNKNOWN FUNCTION OR ARE UNUSED. NEEDS MORE RE.
   --Bit masks are all shown upper nibble first.

   --IO WRITE/READ REGISTERS SIGNALS
   CONSTANT REG_00EE_READ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "01010101"; -- Genuine Xenium
   SIGNAL REG_00EE_WRITE : STD_LOGIC_VECTOR (7 DOWNTO 0) := "00000001"; --X,X,X,X X,B,G,R. Red is default LED colour
   SIGNAL REG_00EF_WRITE : STD_LOGIC_VECTOR (7 DOWNTO 0) := "00000001"; --X,SCK,CS,MOSI, BANKCONTROL[3:0]. Bank 1 is default.
   SIGNAL REG_00EF_READ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "01010101"; --Input signal
   SIGNAL READBUFFER : STD_LOGIC_VECTOR (7 DOWNTO 0); --I buffer Memory and IO reads to reduce pin to pin delay in CPLD which caused issues

   --R/W SIGNAL FOR FLASH MEMORY
   SIGNAL sFLASH_DQ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "ZZZZZZZZ";

   --TSOPBOOT IS SET TO '1' WHEN YOU REQUEST TO BOOT FROM TSOP. THIS PREVENTS THE CPLD FROM DRIVING D0.
   --D0LEVEL is inverted and connected to the D0 output pad. This allows the CPLD to latch/release the D0/LFRAME signal.
   SIGNAL TSOPBOOT : STD_LOGIC := '0';
   SIGNAL D0LEVEL : STD_LOGIC := '0';

   -- Optimized counter for address and data phases
   SIGNAL s_fsm_counter : INTEGER RANGE C_FSM_COUNT_RESET TO C_FSM_ADDR_SEQ_MAX_COUNT;
   SIGNAL s4_io_reg_addr : STD_LOGIC_VECTOR(3 DOWNTO 0);

BEGIN
   --ASSIGN THE IO TO SIGNALS BASED ON REQUIRED BEHAVIOUR
   HEADER_CS <= REG_00EF_WRITE(5);
   HEADER_SCK <= REG_00EF_WRITE(6);
   HEADER_MOSI <= REG_00EF_WRITE(4);

   HEADER_LED_R <= REG_00EE_WRITE(0);
   HEADER_LED_G <= REG_00EE_WRITE(1);
   HEADER_LED_B <= REG_00EE_WRITE(2);

   FLASH_ADDRESS <= LPC_ADDRESS;

   --LAD lines can be either input or output
   --The output values depend on variable states of the LPC transaction
   --Refer to the Intel LPC Specification Rev 1.1
   -- Optimized: Use counter-based approach instead of explicit states
   LPC_LAD <= C_LAD_PATTERN_SYNC WHEN (LPC_CURRENT_STATE = DATA AND s_lad_dir = C_CYC_DIRECTION_READ AND s_fsm_counter = C_FSM_DATA_SEQ_SYNC_READ) ELSE
              C_LAD_PATTERN_SYNC WHEN (LPC_CURRENT_STATE = DATA AND s_lad_dir = C_CYC_DIRECTION_WRITE AND s_fsm_counter = C_FSM_DATA_SEQ_SYNC_WRITE) ELSE
              READBUFFER(3 DOWNTO 0) WHEN (LPC_CURRENT_STATE = DATA AND s_lad_dir = C_CYC_DIRECTION_READ AND s_fsm_counter = C_FSM_DATA_SEQ_DATA1_READ) ELSE
              READBUFFER(7 DOWNTO 4) WHEN (LPC_CURRENT_STATE = DATA AND s_lad_dir = C_CYC_DIRECTION_READ AND s_fsm_counter = C_FSM_DATA_SEQ_DATA2_READ) ELSE
              C_LAD_IDLE_PATTERN WHEN (LPC_CURRENT_STATE = DATA AND s_fsm_counter >= C_FSM_DATA_SEQ_TARA2_READ AND s_fsm_counter <= C_FSM_DATA_SEQ_MAX_COUNT) ELSE
              C_LAD_INPUT_PATTERN;

   --FLASH_DQ is mapped to the data byte sent by the Xbox in MEM_WRITE mode, else its just an input
   FLASH_DQ <= sFLASH_DQ WHEN CYCLE_TYPE = MEM_WRITE ELSE "ZZZZZZZZ";

   --Write Enable for Flash Memory Write (Active low)
   --Minimum pulse width 90ns.
   --Address is latched on the falling edge of WE.
   --Data is latched on the rising edge of WE.
   -- Optimized: Use counter-based approach
   FLASH_WE <= '0' WHEN (CYCLE_TYPE = MEM_WRITE AND LPC_CURRENT_STATE = DATA AND 
                        s_fsm_counter >= C_FSM_DATA_SEQ_TARA2_WRITE AND s_fsm_counter <= C_FSM_DATA_SEQ_SYNC_WRITE) ELSE '1';

   --Output Enable for Flash Memory Read (Active low)
   --Output Enable must be pulled low for 50ns before data is valid for reading
   -- Optimized: Use counter-based approach
   FLASH_OE <= '0' WHEN (CYCLE_TYPE = MEM_READ AND LPC_CURRENT_STATE = DATA AND 
                        s_fsm_counter >= C_FSM_DATA_SEQ_TARA2_READ AND s_fsm_counter <= C_FSM_DATA_SEQ_MAX_COUNT) ELSE '1';

   --D0 has the following behaviour
   --Held low on boot to ensure it boots from the LPC then released when definitely booting from modchip.
   --When soldered to LFRAME it will simulate LPC transaction aborts for 1.6.
   --Released for TSOP booting.
   --NOTE: XENIUM_D0 is an output to a mosfet driver. '0' turns off the MOSFET releasing D0
   --and a value of '1' turns on the MOSFET forcing it to ground. This is why I invert D0LEVEL before mapping it.
   XENIUM_D0 <= '0' WHEN TSOPBOOT = '1' ELSE
                '1' WHEN CYCLE_TYPE = MEM_READ ELSE
                '1' WHEN CYCLE_TYPE = MEM_WRITE ELSE
                NOT D0LEVEL;

   REG_00EF_READ <= XENIUM_RECOVERY & '0' & HEADER_4 & HEADER_1 & REG_00EF_WRITE(3 DOWNTO 0);

   -- Main LPC state machine process - optimized with counter-based approach
   PROCESS (LPC_CLK) BEGIN
      IF rising_edge(LPC_CLK) THEN
         IF LPC_RST = '0' THEN
            --LPC_RST goes low during boot up or hard reset.
            --We need to set D0 only if not TSOP booting.
            D0LEVEL <= TSOPBOOT;
            LPC_CURRENT_STATE <= WAIT_START;
            s_fsm_counter <= C_FSM_COUNT_RESET;
         ELSE
            -- Increment counter
            IF s_fsm_counter < C_FSM_ADDR_SEQ_MAX_COUNT THEN
               s_fsm_counter <= s_fsm_counter + 1;
            ELSE
               s_fsm_counter <= C_FSM_COUNT_RESET;
            END IF;

            CASE LPC_CURRENT_STATE IS
               WHEN WAIT_START =>
                  s_io_cyc <= FALSE;
                  IF LPC_LAD = C_LAD_START_PATTERN AND TSOPBOOT = '0' THEN
                     LPC_CURRENT_STATE <= GET_CYC;
                  END IF;

               WHEN GET_CYC =>
                  -- Release D0 after cycle type is detected
                  IF CYCLE_TYPE = MEM_READ OR CYCLE_TYPE = MEM_WRITE THEN
                     -- D0 is held during memory cycles
                  ELSE
                     -- D0 released for IO cycles
                  END IF;

                  IF LPC_LAD(3 DOWNTO 2) = C_CYC_MEM_PREFIX THEN
                     -- Memory read or write
                     s_fsm_counter <= C_FSM_COUNT_RESET;
                     LPC_CURRENT_STATE <= GET_ADDR;
                     IF LPC_LAD(1) = '0' THEN
                        CYCLE_TYPE <= MEM_READ;
                     ELSE
                        CYCLE_TYPE <= MEM_WRITE;
                     END IF;
                  ELSIF LPC_LAD(3 DOWNTO 2) = C_CYC_IO_PREFIX THEN
                     -- IO read or write
                     s_fsm_counter <= C_FSM_COUNT_IO_START_OFFSET;
                     s_io_cyc <= TRUE;
                     LPC_CURRENT_STATE <= GET_ADDR;
                     IF LPC_LAD(1) = '0' THEN
                        CYCLE_TYPE <= IO_READ;
                     ELSE
                        CYCLE_TYPE <= IO_WRITE;
                     END IF;
                  ELSE
                     LPC_CURRENT_STATE <= WAIT_START; -- Unsupported cycle
                  END IF;
                  s_lad_dir <= LPC_LAD(1);

               WHEN GET_ADDR =>
                  CASE s_fsm_counter IS
                     WHEN C_FSM_ADDR_SEQ_NIBBLE0 | C_FSM_ADDR_SEQ_NIBBLE1 =>
                        -- First 2 nibbles of memory cycle must be "1111"
                        IF NOT s_io_cyc AND LPC_LAD /= C_LAD_ADDR_PATTERN1 THEN
                           LPC_CURRENT_STATE <= WAIT_START;
                        END IF;

                     WHEN C_FSM_ADDR_SEQ_NIBBLE2 =>
                        IF NOT s_io_cyc THEN
                           -- Memory cycle: capture A20
                           LPC_ADDRESS(20) <= LPC_LAD(0);
                        END IF;

                     WHEN C_FSM_ADDR_SEQ_NIBBLE3 =>
                        IF NOT s_io_cyc THEN
                           -- Memory cycle: capture A19-A16 and apply bank selection
                           LPC_ADDRESS(19 DOWNTO 16) <= LPC_LAD;
                           -- Set recovery bank if switch is activated
                           IF XENIUM_RECOVERY = '0' AND TSOPBOOT = '0' AND D0LEVEL = '0' THEN
                              REG_00EF_WRITE(3 DOWNTO 0) <= "1010";
                           END IF;
                           -- Apply bank selection
                           CASE REG_00EF_WRITE(3 DOWNTO 0) IS
                              WHEN "0001" => LPC_ADDRESS(20 DOWNTO 18) <= "110";
                              WHEN "0010" => LPC_ADDRESS(20 DOWNTO 19) <= "10";
                              WHEN "0011" => LPC_ADDRESS(20 DOWNTO 18) <= "000";
                              WHEN "0100" => LPC_ADDRESS(20 DOWNTO 18) <= "001";
                              WHEN "0101" => LPC_ADDRESS(20 DOWNTO 18) <= "010";
                              WHEN "0110" => LPC_ADDRESS(20 DOWNTO 18) <= "011";
                              WHEN "0111" => LPC_ADDRESS(20 DOWNTO 19) <= "00";
                              WHEN "1000" => LPC_ADDRESS(20 DOWNTO 19) <= "01";
                              WHEN "1001" => LPC_ADDRESS(20) <= '0';
                              WHEN "1010" => LPC_ADDRESS(20 DOWNTO 18) <= "111";
                              WHEN "0000" =>
                                 TSOPBOOT <= '1';
                                 LPC_CURRENT_STATE <= WAIT_START;
                              WHEN OTHERS => NULL;
                           END CASE;
                        END IF;

                     WHEN C_FSM_ADDR_SEQ_NIBBLE4 =>
                        IF NOT s_io_cyc THEN
                           LPC_ADDRESS(15 DOWNTO 12) <= LPC_LAD;
                        ELSIF s_io_cyc THEN
                           -- IO address: first nibble should be 0x0 for address 0x0F7E/0x0F7F
                           IF LPC_LAD /= "0000" THEN
                              s_io_cyc <= FALSE;
                           END IF;
                        END IF;

                     WHEN C_FSM_ADDR_SEQ_NIBBLE5 =>
                        IF NOT s_io_cyc THEN
                           LPC_ADDRESS(11 DOWNTO 8) <= LPC_LAD;
                        ELSIF s_io_cyc THEN
                           -- IO address: second nibble should be 0xF
                           IF LPC_LAD /= C_LAD_IOREG_PATTERN1 THEN
                              s_io_cyc <= FALSE;
                           END IF;
                        END IF;

                     WHEN C_FSM_ADDR_SEQ_NIBBLE6 =>
                        IF NOT s_io_cyc THEN
                           LPC_ADDRESS(7 DOWNTO 4) <= LPC_LAD;
                        ELSIF s_io_cyc THEN
                           -- IO address: third nibble should be 0x7
                           IF LPC_LAD /= C_LAD_IOREG_PATTERN2 THEN
                              s_io_cyc <= FALSE;
                           END IF;
                        END IF;

                     WHEN C_FSM_ADDR_SEQ_NIBBLE7 =>
                        IF NOT s_io_cyc THEN
                           LPC_ADDRESS(3 DOWNTO 0) <= LPC_LAD;
                        ELSIF s_io_cyc THEN
                           -- IO address: fourth nibble should be 0xE or 0xF (register 0xEE or 0xEF)
                           -- Verify address byte will be 0xEE or 0xEF (bits 7-1 = 0x77)
                           IF LPC_LAD(3 DOWNTO 1) = "111" THEN
                              s4_io_reg_addr <= LPC_LAD;
                           ELSE
                              s_io_cyc <= FALSE;
                           END IF;
                        END IF;
                        s_fsm_counter <= C_FSM_COUNT_RESET;
                        LPC_CURRENT_STATE <= DATA;

                     WHEN OTHERS => NULL;
                  END CASE;

               WHEN DATA =>
                  -- Handle data phase with counter-based approach
                  IF s_fsm_counter > C_FSM_DATA_SEQ_MAX_COUNT THEN
                     LPC_CURRENT_STATE <= WAIT_START;
                     -- D0 is held low until a few memory reads
                     -- Genuine Xenium releases after the 5th read at address 0x74
                     IF LPC_ADDRESS(7 DOWNTO 0) = x"74" THEN
                        D0LEVEL <= '1';
                     END IF;
                  ELSIF s_lad_dir = C_CYC_DIRECTION_READ THEN
                     -- Read operation: buffer data during sync phase
                     IF s_fsm_counter = C_FSM_DATA_SEQ_SYNC_READ THEN
                        IF CYCLE_TYPE = MEM_READ THEN
                           READBUFFER <= FLASH_DQ;
                        ELSIF CYCLE_TYPE = IO_READ AND s_io_cyc THEN
                           -- Use s4_io_reg_addr to determine which register (0xEE or 0xEF)
                           IF s4_io_reg_addr(0) = '0' THEN
                              READBUFFER <= REG_00EE_READ;
                           ELSE
                              READBUFFER <= REG_00EF_READ;
                           END IF;
                        END IF;
                     END IF;
                  ELSIF s_lad_dir = C_CYC_DIRECTION_WRITE THEN
                     -- Write operation: capture data
                     IF s_fsm_counter = C_FSM_DATA_WRITE_LO_NIBBLE_OFFSET THEN
                        IF CYCLE_TYPE = MEM_WRITE THEN
                           sFLASH_DQ(3 DOWNTO 0) <= LPC_LAD;
                        ELSIF s_io_cyc THEN
                           IF s4_io_reg_addr(0) = '0' THEN
                              REG_00EE_WRITE(3 DOWNTO 0) <= LPC_LAD;
                           ELSE
                              REG_00EF_WRITE(3 DOWNTO 0) <= LPC_LAD;
                           END IF;
                        END IF;
                     ELSIF s_fsm_counter = C_FSM_DATA_WRITE_HI_NIBBLE_OFFSET THEN
                        IF CYCLE_TYPE = MEM_WRITE THEN
                           sFLASH_DQ(7 DOWNTO 4) <= LPC_LAD;
                        ELSIF s_io_cyc THEN
                           IF s4_io_reg_addr(0) = '0' THEN
                              REG_00EE_WRITE(7 DOWNTO 4) <= LPC_LAD;
                           ELSE
                              REG_00EF_WRITE(7 DOWNTO 4) <= LPC_LAD;
                           END IF;
                        END IF;
                     END IF;
                  END IF;
            END CASE;
         END IF;
      END IF;
   END PROCESS;
END Behavioral;
