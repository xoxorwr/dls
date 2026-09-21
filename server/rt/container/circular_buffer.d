module rt.container.circular_buffer;

struct CircularBuffer(T, size_t CAPACITY)
{
    size_t m_front;
    size_t m_back;
    size_t m_nextFree;
    size_t m_size;
    T[CAPACITY] m_data = T.init;

    T pop_front()
    {
        assert(m_size > 0, "Invalid buffer size");
        auto ret = front();

        m_front = (m_front + 1) % m_data.length;
        m_size--;

        return ret;
    }

    void push_back(const ref T value)
    {
        assert(m_size < m_data.length, "Buffer full");
        m_data[m_nextFree] = value;
        m_back = m_nextFree;
        m_nextFree = (m_back + 1) % m_data.length;

        m_size++;
    }

    ref T front()
    {
        assert(m_size > 0, "Invalid buffer size");
        return m_data[m_front];
    }

    ref T back()
    {
        assert(m_size > 0, "Invalid buffer size");
        return m_data[m_back];
    }

    size_t size()
    {
        return m_size;
    }

    size_t capacity()
    {
        return CAPACITY;
    }
}
