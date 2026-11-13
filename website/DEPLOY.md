# Deploy a transportcat.app

El sitio vive en `website/` dentro de este repo. Es 100% estático: HTML + CSS +
un JS mínimo, sin framework, sin build step y sin dependencias.

## Cloudflare Pages (elegido — el dominio ya está en Cloudflare)

1. Cloudflare dashboard → **Workers & Pages → Create → Pages → Connect to Git**.
2. Selecciona el repo `albert-castellvi/TransportCat`.
3. Configuración del proyecto:
   - **Production branch**: `main`
   - **Build command**: *vacío* (no hay build)
   - **Build output directory**: `website`
   - **Root directory (avanzado)**: `website` — así los cambios de la app no
     disparan deploys de la web.
4. Custom domain: añade `transportcat.app` (zone ya gestionada por Cloudflare,
   el DNS se crea solo).
5. Deploy. HTTPS y HTTP/3 van incluidos.

### Reglas para evitar deploys inútiles

Settings → Builds & deployments → **Ignore deployments**: `^((?!website/).)*$`
(solo despliega cuando cambian ficheros bajo `website/`).

## Pendiente al publicar la app

- Reemplazar los `href="#"` de los botones «Descarregar / Descargar /
  Download» por la URL real del App Store (buscar `TODO: replace #`).
- La landing anuncia Rodalies como «en desarrollo»: actualizar el capítulo
  cuando salga.

## Estructura

```
website/
├── index.html            # ca (por defecto)
├── privadesa.html        # política de privacidad (ca)  → /privadesa
├── suport.html           # soporte (ca)                  → /suport
├── 404.html
├── sitemap.xml · robots.txt · favicon.svg
├── es/  (index, privadesa, soporte)
├── en/  (index, privacy, support)
├── css/main.css          # sistema de diseño completo
├── js/main.js            # IntersectionObserver, respeta prefers-reduced-motion
└── assets/*.jpg          # capturas reales del simulador (iPhone 17 Pro, iOS 26)
```

Cloudflare Pages sirve `/privadesa` desde `privadesa.html` automáticamente
(pretty URLs). No hay redirecciones que configurar.

## Requisitos ASC cubiertos por la web

- **Privacy Policy URL** → `https://transportcat.app/privadesa`
- **Support URL** → `https://transportcat.app/suport`
- **Marketing URL** → `https://transportcat.app/`
