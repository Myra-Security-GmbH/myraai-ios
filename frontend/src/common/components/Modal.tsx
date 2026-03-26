import s from "src/common/components/layout/Layout.module.scss";

function CloseIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </svg>
  );
}

interface ModalProps {
  title: React.ReactNode;
  onClose: () => void;
  error?: string | null;
  children: React.ReactNode;
  disableOverlayClose?: boolean;
  modalStyle?: React.CSSProperties;
}

export function Modal({ title, onClose, error, children, disableOverlayClose, modalStyle }: ModalProps) {
  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && !disableOverlayClose && onClose()}>
      <div className={s.modal} style={modalStyle}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>{title}</h2>
          <button className={s["modal-close"]} onClick={onClose}><CloseIcon /></button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        {children}
      </div>
    </div>
  );
}
