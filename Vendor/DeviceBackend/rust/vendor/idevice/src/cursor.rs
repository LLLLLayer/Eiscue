// Jackson Coxson

#[derive(Clone, Debug)]
pub struct Cursor<'a> {
    inner: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    /// Creates a new cursor
    pub fn new(inner: &'a [u8]) -> Self {
        Self { inner, pos: 0 }
    }

    pub fn len(&self) -> usize {
        self.inner.len()
    }

    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    pub fn at_end(&self) -> bool {
        self.pos == self.inner.len()
    }

    pub fn read(&mut self, to_read: usize) -> Option<&'a [u8]> {
        // Check if the end of the slice (self.pos + to_read) is beyond the buffer length
        if self
            .pos
            .checked_add(to_read)
            .is_none_or(|end_pos| end_pos > self.inner.len())
        {
            return None;
        }

        // The end of the slice is self.pos + to_read
        let end_pos = self.pos + to_read;
        let res = Some(&self.inner[self.pos..end_pos]);
        self.pos = end_pos;
        res
    }

    pub fn back(&mut self, to_back: usize) {
        let to_back = if to_back > self.pos {
            self.pos
        } else {
            to_back
        };

        self.pos -= to_back;
    }

    /// True if actually all zeroes
    pub fn read_assert_zero(&mut self, to_read: usize) -> Option<()> {
        let bytes = self.read(to_read)?;

        #[cfg(not(debug_assertions))]
        let _ = bytes;

        #[cfg(debug_assertions)]
        for b in bytes.iter() {
            if *b > 0 {
                return None;
            }
        }

        Some(())
    }

    pub fn read_to(&mut self, end: usize) -> Option<&'a [u8]> {
        if end > self.inner.len() {
            return None;
        }
        let res = Some(&self.inner[self.pos..end]);
        self.pos = end;
        res
    }

    pub fn peek_to(&mut self, end: usize) -> Option<&'a [u8]> {
        if end > self.inner.len() {
            return None;
        }
        Some(&self.inner[self.pos..end])
    }

    pub fn peek(&self, to_read: usize) -> Option<&'a [u8]> {
        if self
            .pos
            .checked_add(to_read)
            .is_none_or(|end_pos| end_pos > self.inner.len())
        {
            return None;
        }

        let end_pos = self.pos + to_read;
        Some(&self.inner[self.pos..end_pos])
    }

    pub fn reveal(&self, surrounding: usize) {
        // Protocol buffers can contain identity keys or screen data. Keep diagnostics structural.
        tracing::trace!(position = self.pos, length = self.inner.len(), surrounding, "Cursor position");
    }

    pub fn remaining(&mut self) -> &'a [u8] {
        let res = &self.inner[self.pos..];
        self.pos = self.inner.len();
        res
    }

    pub fn read_u8(&mut self) -> Option<u8> {
        if self.pos == self.inner.len() {
            return None;
        }
        let res = Some(self.inner[self.pos]);
        self.pos += 1;
        res
    }

    pub fn read_le_u16(&mut self) -> Option<u16> {
        const SIZE: usize = 2;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(u16::from_le_bytes(bytes))
    }

    pub fn read_be_u16(&mut self) -> Option<u16> {
        const SIZE: usize = 2;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(u16::from_be_bytes(bytes))
    }

    pub fn read_le_u32(&mut self) -> Option<u32> {
        const SIZE: usize = 4;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(u32::from_le_bytes(bytes))
    }

    pub fn read_be_u32(&mut self) -> Option<u32> {
        const SIZE: usize = 4;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(u32::from_be_bytes(bytes))
    }

    pub fn read_le_u64(&mut self) -> Option<u64> {
        const SIZE: usize = 8;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(u64::from_le_bytes(bytes))
    }

    pub fn read_be_u64(&mut self) -> Option<u64> {
        const SIZE: usize = 8;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(u64::from_be_bytes(bytes))
    }

    pub fn read_le_u128(&mut self) -> Option<u128> {
        const SIZE: usize = 16;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(u128::from_le_bytes(bytes))
    }

    pub fn read_be_u128(&mut self) -> Option<u128> {
        const SIZE: usize = 16;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(u128::from_be_bytes(bytes))
    }

    pub fn read_le_f32(&mut self) -> Option<f32> {
        const SIZE: usize = 4;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(f32::from_le_bytes(bytes))
    }

    pub fn read_be_f32(&mut self) -> Option<f32> {
        const SIZE: usize = 4;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(f32::from_be_bytes(bytes))
    }

    pub fn read_i8(&mut self) -> Option<i8> {
        if self.pos == self.inner.len() {
            return None;
        }
        let res = Some(self.inner[self.pos]).map(|x| x as i8);
        self.pos += 1;
        res
    }

    pub fn read_le_i16(&mut self) -> Option<i16> {
        const SIZE: usize = 2;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(i16::from_le_bytes(bytes))
    }

    pub fn read_be_i16(&mut self) -> Option<i16> {
        const SIZE: usize = 2;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(i16::from_be_bytes(bytes))
    }

    pub fn read_le_i32(&mut self) -> Option<i32> {
        const SIZE: usize = 4;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(i32::from_le_bytes(bytes))
    }

    pub fn read_be_i32(&mut self) -> Option<i32> {
        const SIZE: usize = 4;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(i32::from_be_bytes(bytes))
    }

    pub fn read_le_i64(&mut self) -> Option<i64> {
        const SIZE: usize = 8;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(i64::from_le_bytes(bytes))
    }

    pub fn read_be_i64(&mut self) -> Option<i64> {
        const SIZE: usize = 8;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(i64::from_be_bytes(bytes))
    }

    pub fn read_le_i128(&mut self) -> Option<i128> {
        const SIZE: usize = 16;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(i128::from_le_bytes(bytes))
    }

    pub fn read_be_i128(&mut self) -> Option<i128> {
        const SIZE: usize = 16;
        let bytes = self.read(SIZE)?;
        let bytes: [u8; SIZE] = bytes.try_into().unwrap();
        Some(i128::from_be_bytes(bytes))
    }

    pub fn take_2(&mut self) -> Option<[u8; 2]> {
        let bytes = self.read(2)?;
        Some(bytes.to_owned().try_into().unwrap())
    }

    pub fn take_3(&mut self) -> Option<[u8; 3]> {
        let bytes = self.read(3)?;
        Some(bytes.to_owned().try_into().unwrap())
    }

    pub fn take_4(&mut self) -> Option<[u8; 4]> {
        let bytes = self.read(4)?;
        Some(bytes.to_owned().try_into().unwrap())
    }

    pub fn take_8(&mut self) -> Option<[u8; 8]> {
        let bytes = self.read(8)?;
        Some(bytes.to_owned().try_into().unwrap())
    }

    pub fn take_20(&mut self) -> Option<[u8; 20]> {
        let bytes = self.read(20)?;
        Some(bytes.to_owned().try_into().unwrap())
    }

    pub fn take_32(&mut self) -> Option<[u8; 32]> {
        let bytes = self.read(32)?;
        Some(bytes.to_owned().try_into().unwrap())
    }
}
