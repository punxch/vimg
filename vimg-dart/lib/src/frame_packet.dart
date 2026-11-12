typedef FramePacket = ({double seconds, int offset, int size});

typedef FrameVisitor = void Function(FramePacket packet, bool sync);
