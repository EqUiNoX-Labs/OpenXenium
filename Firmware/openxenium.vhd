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

   -- Simplified state machine based on XBlast approach
   TYPE LPC_STATE_MACHINE IS (
   WAIT_START,  -- Wait for start pattern
   GET_CYC,     -- Get cycle type
   GET_ADDR,    -- Get address (8 nibbles for MEM, 4 for IO)
   DATA         -- Data transfer phase
   );

   SIGNAL LPC_CURRENT_STATE : LPC_STATE_MACHINE;
   SIGNAL LAD_DIR : STD_LOGIC;  -- '0' for read, '1' for write
   SIGNAL IO_CYC : BOOLEAN;     -- True for IO cycles
   SIGNAL COUNT : INTEGER RANGE 0 TO 7;  -- Single counter for address and data

   SIGNAL LPC_ADDRESS : STD_LOGIC_VECTOR (20 DOWNTO 0);

   --XENIUM IO REGISTERS
   CONSTANT REG_00EE_READ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "01010101";
   SIGNAL REG_00EE_WRITE : STD_LOGIC_VECTOR (7 DOWNTO 0) := "00000001";
   SIGNAL REG_00EF_WRITE : STD_LOGIC_VECTOR (7 DOWNTO 0) := "00000001";
   SIGNAL REG_00EF_READ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "01010101";
   SIGNAL READBUFFER : STD_LOGIC_VECTOR (7 DOWNTO 0);
   SIGNAL sFLASH_DQ : STD_LOGIC_VECTOR (7 DOWNTO 0) := "ZZZZZZZZ";

   SIGNAL TSOPBOOT : STD_LOGIC := '0';
   SIGNAL D0LEVEL : STD_LOGIC := '0';
   SIGNAL IO_REG_ADDR : STD_LOGIC_VECTOR (3 DOWNTO 0);

BEGIN
   --ASSIGN THE IO TO SIGNALS BASED ON REQUIRED BEHAVIOUR
   HEADER_CS <= REG_00EF_WRITE(5);   -- Really need to put this back in somehow. 100% full :(
   HEADER_SCK <= REG_00EF_WRITE(6);
   HEADER_MOSI <= REG_00EF_WRITE(4);

   HEADER_LED_R <= REG_00EE_WRITE(0);
   HEADER_LED_G <= REG_00EE_WRITE(1);
   HEADER_LED_B <= REG_00EE_WRITE(2);

   FLASH_ADDRESS <= LPC_ADDRESS;

   --LAD output: simplified for new state machine
   LPC_LAD <= "0000" WHEN (LPC_CURRENT_STATE = DATA AND LAD_DIR = '0' AND COUNT = 2) ELSE
              "1111" WHEN (LPC_CURRENT_STATE = DATA AND COUNT >= 3 AND COUNT <= 4) ELSE
              READBUFFER(3 DOWNTO 0) WHEN (LPC_CURRENT_STATE = DATA AND LAD_DIR = '0' AND COUNT = 5) ELSE
              READBUFFER(7 DOWNTO 4) WHEN (LPC_CURRENT_STATE = DATA AND LAD_DIR = '0' AND COUNT = 6) ELSE
              "ZZZZ";

   --FLASH_DQ is mapped to the data byte sent by the Xbox in memory write mode, else its just an input
   FLASH_DQ <= sFLASH_DQ WHEN (LPC_CURRENT_STATE = DATA AND LAD_DIR = '1' AND NOT IO_CYC) ELSE "ZZZZZZZZ";

   --Flash control: simplified for new state machine
   FLASH_WE <= '0' WHEN (LPC_CURRENT_STATE = DATA AND LAD_DIR = '1' AND NOT IO_CYC AND COUNT >= 3 AND COUNT <= 5) ELSE '1';
   FLASH_OE <= '0' WHEN (LPC_CURRENT_STATE = DATA AND LAD_DIR = '0' AND NOT IO_CYC AND COUNT >= 2 AND COUNT <= 6) ELSE '1';

   --D0 control: simplified
   XENIUM_D0 <= '0' WHEN TSOPBOOT = '1' ELSE
                '1' WHEN (LPC_CURRENT_STATE = DATA AND NOT IO_CYC) ELSE
                NOT D0LEVEL;

   REG_00EF_READ <= XENIUM_RECOVERY & '0' & HEADER_4 & HEADER_1 & REG_00EF_WRITE(3 DOWNTO 0);

PROCESS (LPC_CLK, LPC_RST) BEGIN
   IF (LPC_RST = '0') THEN
      D0LEVEL <= TSOPBOOT;
      LPC_CURRENT_STATE <= WAIT_START;
      COUNT <= 0;
   ELSIF (rising_edge(LPC_CLK)) THEN
      CASE LPC_CURRENT_STATE IS
         WHEN WAIT_START =>
            IF LPC_LAD = "0000" AND TSOPBOOT = '0' THEN
               LPC_CURRENT_STATE <= GET_CYC;
            END IF;
         WHEN GET_CYC =>
            IF LPC_LAD(3 DOWNTO 2) = "01" THEN
               -- Memory cycle
               LAD_DIR <= LPC_LAD(1);
               COUNT <= 0;
               LPC_CURRENT_STATE <= GET_ADDR;
            ELSIF LPC_LAD(3 DOWNTO 2) = "00" THEN
               -- IO cycle
               LAD_DIR <= LPC_LAD(1);
               IO_CYC <= TRUE;
               COUNT <= 3;
               LPC_CURRENT_STATE <= GET_ADDR;
            ELSE
               LPC_CURRENT_STATE <= WAIT_START;
            END IF;

         WHEN GET_ADDR =>
            IF NOT IO_CYC THEN
               -- Memory cycle: 8 address nibbles (count 0-7)
               IF COUNT = 0 THEN
                  LPC_ADDRESS(20) <= LPC_LAD(0);
                  COUNT <= COUNT + 1;
               ELSIF COUNT = 1 THEN
                  LPC_ADDRESS(19 DOWNTO 16) <= LPC_LAD;
                  COUNT <= COUNT + 1;
               ELSIF COUNT = 2 THEN
                  LPC_ADDRESS(15 DOWNTO 12) <= LPC_LAD;
                  COUNT <= COUNT + 1;
               ELSIF COUNT = 3 THEN
                  LPC_ADDRESS(11 DOWNTO 8) <= LPC_LAD;
                  COUNT <= COUNT + 1;
               ELSIF COUNT = 4 THEN
                  LPC_ADDRESS(7 DOWNTO 4) <= LPC_LAD;
                  -- Bank control
                  IF XENIUM_RECOVERY = '0' AND TSOPBOOT = '0' AND D0LEVEL = '0' THEN
                     REG_00EF_WRITE(3 DOWNTO 0) <= "1010";
                  END IF;
                  IF REG_00EF_WRITE(3 DOWNTO 0) = "0000" THEN
                     TSOPBOOT <= '1';
                     LPC_CURRENT_STATE <= WAIT_START;
                  ELSE
                     -- Bank selection matching documentation
                     -- A20: High for 0001, 0010, 1010; Low for others
                     LPC_ADDRESS(20) <= (NOT REG_00EF_WRITE(3) AND NOT REG_00EF_WRITE(2) AND (REG_00EF_WRITE(1) XOR REG_00EF_WRITE(0))) OR
                                       (REG_00EF_WRITE(3) AND NOT REG_00EF_WRITE(2) AND REG_00EF_WRITE(1) AND NOT REG_00EF_WRITE(0));
                     -- A19: 1 for 0001,1010; 0 for 0010; bank(1) for 0011-0110; bank(0) for 0111-1000; 0 for 1001
                     IF REG_00EF_WRITE(3 DOWNTO 0) = "0001" OR REG_00EF_WRITE(3 DOWNTO 0) = "1010" THEN
                        LPC_ADDRESS(19) <= '1';  -- 0001: 1|1|0, 1010: 1|1|1
                     ELSIF REG_00EF_WRITE(3 DOWNTO 0) = "0010" THEN
                        LPC_ADDRESS(19) <= '0';  -- 0010: 1|0|X
                     ELSIF REG_00EF_WRITE(3) = '0' AND REG_00EF_WRITE(2) = '1' THEN
                        LPC_ADDRESS(19) <= REG_00EF_WRITE(1);  -- 0011-0110: 0|bank(1)|bank(0)
                     ELSIF REG_00EF_WRITE(3) = '1' AND REG_00EF_WRITE(2) = '0' THEN
                        LPC_ADDRESS(19) <= REG_00EF_WRITE(0);  -- 0111-1000: 0|bank(0)|X
                     ELSE
                        LPC_ADDRESS(19) <= '0';  -- 1001: 0|X|X (default to 0)
                     END IF;
                     -- A18: 0 for 0001; X for 0010; bank(0) for 0011-0110; X for 0111-1000; X for 1001; 1 for 1010
                     IF REG_00EF_WRITE(3 DOWNTO 0) = "0001" THEN
                        LPC_ADDRESS(18) <= '0';  -- 0001: 1|1|0
                     ELSIF REG_00EF_WRITE(3 DOWNTO 0) = "1010" THEN
                        LPC_ADDRESS(18) <= '1';  -- 1010: 1|1|1
                     ELSIF REG_00EF_WRITE(3) = '0' AND REG_00EF_WRITE(2) = '1' THEN
                        LPC_ADDRESS(18) <= REG_00EF_WRITE(0);  -- 0011-0110: 0|bank(1)|bank(0)
                     ELSE
                        LPC_ADDRESS(18) <= '0';  -- Others: X (default to 0 for 0010,0111-1001)
                     END IF;
                  END IF;
                  COUNT <= COUNT + 1;
               ELSIF COUNT = 5 THEN
                  LPC_ADDRESS(3 DOWNTO 0) <= LPC_LAD;
                  COUNT <= 0;
                  LPC_CURRENT_STATE <= DATA;
               ELSE
                  COUNT <= COUNT + 1;
               END IF;
            ELSE
               -- IO cycle: 4 address nibbles (count 3-0)
               IF COUNT = 3 THEN
                  IF LPC_LAD = x"0" THEN
                     COUNT <= COUNT - 1;
                  ELSE
                     IO_CYC <= FALSE;
                     LPC_CURRENT_STATE <= WAIT_START;
                  END IF;
               ELSIF COUNT = 2 THEN
                  IF LPC_LAD = x"0" THEN
                     COUNT <= COUNT - 1;
                  ELSE
                     IO_CYC <= FALSE;
                     LPC_CURRENT_STATE <= WAIT_START;
                  END IF;
               ELSIF COUNT = 1 THEN
                  IF LPC_LAD = x"7" THEN
                     IO_REG_ADDR <= LPC_LAD;
                     COUNT <= COUNT - 1;
                  ELSE
                     IO_CYC <= FALSE;
                     LPC_CURRENT_STATE <= WAIT_START;
                  END IF;
               ELSIF COUNT = 0 THEN
                  IF LPC_LAD = x"E" OR LPC_LAD = x"F" THEN
                     LPC_ADDRESS(7 DOWNTO 0) <= LPC_LAD & IO_REG_ADDR;
                     COUNT <= 0;
                     LPC_CURRENT_STATE <= DATA;
                  ELSE
                     IO_CYC <= FALSE;
                     LPC_CURRENT_STATE <= WAIT_START;
                  END IF;
               END IF;
            END IF;

         WHEN DATA =>
            -- Data phase: TAR (2 cycles), SYNC (1 cycle), DATA (2 cycles) = 5 cycles total
            IF COUNT >= 4 THEN
               LPC_CURRENT_STATE <= WAIT_START;
               IO_CYC <= FALSE;
               IF LPC_ADDRESS(7 DOWNTO 0) = x"74" THEN
                  D0LEVEL <= '1';
               END IF;
            ELSIF LAD_DIR = '1' THEN
               -- Write operation
               IF COUNT = 0 THEN
                  IF IO_CYC THEN
                     IF LPC_ADDRESS(0) = '0' THEN
                        REG_00EE_WRITE(3 DOWNTO 0) <= LPC_LAD;
                     ELSE
                        REG_00EF_WRITE(3 DOWNTO 0) <= LPC_LAD;
                     END IF;
                  ELSE
                     sFLASH_DQ(3 DOWNTO 0) <= LPC_LAD;
                  END IF;
                  COUNT <= COUNT + 1;
               ELSIF COUNT = 1 THEN
                  IF IO_CYC THEN
                     IF LPC_ADDRESS(0) = '0' THEN
                        REG_00EE_WRITE(7 DOWNTO 4) <= LPC_LAD;
                     ELSE
                        REG_00EF_WRITE(7 DOWNTO 4) <= LPC_LAD;
                     END IF;
                  ELSE
                     sFLASH_DQ(7 DOWNTO 4) <= LPC_LAD;
                  END IF;
                  COUNT <= COUNT + 1;
               ELSE
                  COUNT <= COUNT + 1;
               END IF;
            ELSE
               -- Read operation: buffer data during SYNC (count=2)
               IF COUNT = 2 THEN
                  IF IO_CYC THEN
                     IF LPC_ADDRESS(0) = '0' THEN
                        READBUFFER <= REG_00EE_READ;
                     ELSE
                        READBUFFER <= REG_00EF_READ;
                     END IF;
                  ELSE
                     READBUFFER <= FLASH_DQ;
                  END IF;
                  COUNT <= COUNT + 1;
               ELSE
                  COUNT <= COUNT + 1;
               END IF;
            END IF;
      END CASE;
   END IF;
END PROCESS;
END Behavioral;
