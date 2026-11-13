# Deploy a transportcat.app

El sitio vive en `website/` dentro de este repo. Es 100% estático: HTML + CSS +
un JS mínimo, sin framework, sin build step y sin dependencias.

## Cloudflare Pages vía GitHub Actions (elegido)

El workflow `.github/workflows/deploy-web.yml` publica `website/` en el proyecto
Pages `transportcat` con cada cambio en `main` que toque `website/` (o con
`workflow_dispatch` manual desde la pestaña Actions). Requiere, una vez:

1. Proyecto Pages creado: dashboard → *Workers & Pages* → *Create* → *Pages* →
   *Upload assets* → nombre `transportcat`, production branch `main` (o
   `wrangler pages project create transportcat --production-branch=main`).
2. Token de API con permiso *Account · Cloudflare Pages · Edit*, guardado como
   secret `CLOUDFLARE_API_TOKEN` en el repo, junto con `CLOUDFLARE_ACCOUNT_ID`.
3. (Opcional) Environment `website` en GitHub con deployment branch policy `main`.

Las dos actions del workflow van pineadas a SHA de su tag. Las app pushes que no
tocan `website/` no disparan deploy (paths filter).

Después del primer deploy verde: proyecto `transportcat` → *Custom domains* →
añadir `transportcat.app` (la zone ya está en Cloudflare; el DNS se crea solo).

## Alternativa no usada: integración Git de Pages

Conectar el repo desde el dashboard de Pages también funcionaría (build command
vacío, output `website`), pero se descartó por tener el deploy visible y
auditado en Actions, junto al resto de la pipeline.

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
